import 'dart:convert';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import '../common/core_error.dart';
import '../bilibili_site.dart';

enum BiliBiliAccountState { valid, expired, riskControl, unavailable }

class BiliBiliAccountResult {
  final BiliBiliAccountState state;
  final int uid;
  final String name;
  BiliBiliAccountResult(this.state, {this.uid = 0, this.name = ''});
}

enum BiliBiliLoginState { waiting, scanned, expired, confirmed, failed }

class BiliBiliLoginResult {
  final BiliBiliLoginState state;
  final String? cookie;
  BiliBiliLoginResult(this.state, {this.cookie});
}

/// Isolated QR transaction: seed device cookies before generating the QR code,
/// retain all scoped response cookies, and validate identity before export.
class BiliBiliLoginClient {
  BiliBiliLoginClient({Dio? dio})
      : _ownsDio = dio == null,
        _dio = dio ?? newDio();
  final Dio _dio;
  final bool _ownsDio;
  final _jar = CookieJar();
  final _cancel = CancelToken();
  String? _key;
  bool _busy = false;
  static Dio newDio() => Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 20),
      sendTimeout: const Duration(seconds: 20)));
  static const _headers = {
    'User-Agent': BiliBiliSite.kDefaultUserAgent,
    'Referer': BiliBiliSite.kDefaultReferer,
  };

  static Map _json(dynamic body) {
    try {
      final value = body is String ? jsonDecode(body) : body;
      if (value is Map) return value;
    } catch (_) {}
    throw CoreError('哔哩哔哩响应无效，请稍后重试');
  }

  Future<Response<dynamic>> _request(String url) async {
    final uri = Uri.parse(url);
    final cookies = await _jar.loadForRequest(uri);
    final response = await _dio.getUri(uri,
        cancelToken: _cancel,
        options: Options(
            responseType: ResponseType.plain,
            followRedirects: false,
            headers: {
              ..._headers,
              if (cookies.isNotEmpty)
                'Cookie': cookies.map((c) => '${c.name}=${c.value}').join('; ')
            },
            extra: {
              'sensitive': true
            }));
    await _jar.saveFromResponse(
        uri,
        (response.headers['set-cookie'] ?? [])
            .map(Cookie.fromSetCookieValue)
            .toList());
    return response;
  }

  Future<String> create() async {
    final spi = _json(
        (await _request('https://api.bilibili.com/x/frontend/finger/spi'))
            .data);
    if ('${spi['code']}' != '0' || spi['data'] is! Map) {
      throw CoreError('哔哩哔哩设备初始化失败，请重试');
    }
    final devices = <Cookie>[];
    for (final entry in {'buvid3': 'b_3', 'buvid4': 'b_4'}.entries) {
      final value = spi['data'][entry.value];
      if (value is String && value.isNotEmpty) {
        devices.add(Cookie(entry.key, value)
          ..domain = '.bilibili.com'
          ..path = '/'
          ..secure = true);
      }
    }
    if (devices.length != 2) throw CoreError('哔哩哔哩设备标识不完整，请重试');
    await _jar.saveFromResponse(
        Uri.parse('https://api.bilibili.com/'), devices);
    final obj = _json((await _request(
            'https://passport.bilibili.com/x/passport-login/web/qrcode/generate'))
        .data);
    final data = obj['data'];
    if ('${obj['code']}' != '0' ||
        data is! Map ||
        data['qrcode_key'] is! String ||
        (data['qrcode_key'] as String).isEmpty) {
      throw CoreError('哔哩哔哩二维码获取失败');
    }
    final uri = Uri.tryParse('${data['url']}');
    if (uri == null ||
        uri.scheme != 'https' ||
        !(uri.host == 'bilibili.com' || uri.host.endsWith('.bilibili.com'))) {
      throw CoreError('哔哩哔哩二维码地址无效');
    }
    _key = data['qrcode_key'];
    return uri.toString();
  }

  Future<BiliBiliLoginResult> poll() async {
    if (_key == null || _busy) throw CoreError('哔哩哔哩登录事务不可用');
    _busy = true;
    try {
      final obj = _json((await _request(
              'https://passport.bilibili.com/x/passport-login/web/qrcode/poll?qrcode_key=${Uri.encodeQueryComponent(_key!)}'))
          .data);
      if ('${obj['code']}' != '0' || obj['data'] is! Map) {
        return BiliBiliLoginResult(BiliBiliLoginState.failed);
      }
      switch ('${obj['data']['code']}') {
        case '86038':
          return BiliBiliLoginResult(BiliBiliLoginState.expired);
        case '86090':
          return BiliBiliLoginResult(BiliBiliLoginState.scanned);
        case '86101':
          return BiliBiliLoginResult(BiliBiliLoginState.waiting);
        case '0':
          break;
        default:
          return BiliBiliLoginResult(BiliBiliLoginState.failed);
      }
      final cookies =
          await _jar.loadForRequest(Uri.parse('https://api.bilibili.com/'));
      final cookie = cookies.map((c) => '${c.name}=${c.value}').join('; ');
      final account =
          await checkAccount(cookie, dio: _dio, cancelToken: _cancel);
      if (account.state != BiliBiliAccountState.valid) {
        return BiliBiliLoginResult(BiliBiliLoginState.failed);
      }
      return BiliBiliLoginResult(BiliBiliLoginState.confirmed, cookie: cookie);
    } finally {
      _busy = false;
    }
  }

  static Future<BiliBiliAccountResult> checkAccount(String cookie,
      {Dio? dio, CancelToken? cancelToken}) async {
    if (cookie.isEmpty) {
      return BiliBiliAccountResult(BiliBiliAccountState.expired);
    }
    final client = dio ?? newDio();
    try {
      final response = await client.get(
          'https://api.bilibili.com/x/web-interface/nav',
          cancelToken: cancelToken,
          options: Options(
              headers: {..._headers, 'Cookie': cookie},
              responseType: ResponseType.plain,
              followRedirects: false,
              validateStatus: (_) => true,
              extra: {'sensitive': true}));
      if (response.statusCode == 412) {
        return BiliBiliAccountResult(BiliBiliAccountState.riskControl);
      }
      if ([401, 403].contains(response.statusCode)) {
        return BiliBiliAccountResult(BiliBiliAccountState.expired);
      }
      if (response.statusCode != 200) {
        return BiliBiliAccountResult(BiliBiliAccountState.unavailable);
      }
      final obj = _json(response.data);
      if ('${obj['code']}' == '-352') {
        return BiliBiliAccountResult(BiliBiliAccountState.riskControl);
      }
      if ('${obj['code']}' == '-101') {
        return BiliBiliAccountResult(BiliBiliAccountState.expired);
      }
      if ('${obj['code']}' != '0' || obj['data'] is! Map) {
        return BiliBiliAccountResult(BiliBiliAccountState.unavailable);
      }
      final data = obj['data'];
      if (data['isLogin'] == false || data['isLogin'] == 0) {
        return BiliBiliAccountResult(BiliBiliAccountState.expired);
      }
      final uid = int.tryParse('${data['mid']}') ?? 0;
      if ((data['isLogin'] != true && data['isLogin'] != 1) || uid <= 0) {
        return BiliBiliAccountResult(BiliBiliAccountState.unavailable);
      }
      return BiliBiliAccountResult(BiliBiliAccountState.valid,
          uid: uid, name: '${data['uname'] ?? ''}');
    } finally {
      if (dio == null) client.close();
    }
  }

  void close() {
    _cancel.cancel('login closed');
    if (_ownsDio) _dio.close(force: true);
  }
}
