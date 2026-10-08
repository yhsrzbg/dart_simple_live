import 'dart:convert';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import '../common/core_error.dart';

enum DouyuLoginState { waiting, scanned, expired, confirmed, failed }

class DouyuLoginChallenge {
  final String qrContent;
  final DateTime? expiresAt;
  DouyuLoginChallenge(this.qrContent, this.expiresAt);
}

class DouyuLoginResult {
  final DouyuLoginState state;
  final String? cookie;
  DouyuLoginResult(this.state, {this.cookie});
}

/// One isolated QR login transaction. Never uses the shared logging client.
class DouyuLoginClient {
  DouyuLoginClient({Dio? dio})
      : _ownsDio = dio == null,
        _dio = dio ??
            Dio(BaseOptions(
                connectTimeout: const Duration(seconds: 20),
                receiveTimeout: const Duration(seconds: 20)));

  final Dio _dio;
  final bool _ownsDio;
  final _jar = CookieJar();
  final _cancel = CancelToken();
  String? _code;
  bool _busy = false;
  static const _headers = {
    'Referer': 'https://passport.douyu.com/member/login',
    'User-Agent':
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36',
    'X-Requested-With': 'XMLHttpRequest',
  };

  static bool _allowed(Uri uri) =>
      uri.scheme == 'https' &&
      (uri.host == 'douyu.com' || uri.host.endsWith('.douyu.com'));

  Future<Response<dynamic>> _request(Uri uri,
      {String method = 'GET', String? body}) async {
    for (var redirects = 0; redirects < 8; redirects++) {
      if (!_allowed(uri)) throw CoreError('斗鱼登录地址无效');
      final cookies = await _jar.loadForRequest(uri);
      final response = await _dio.requestUri(uri,
          data: body,
          cancelToken: _cancel,
          options: Options(
              method: method,
              responseType: ResponseType.plain,
              contentType: Headers.formUrlEncodedContentType,
              followRedirects: false,
              validateStatus: (status) => status != null && status < 400,
              headers: {
                ..._headers,
                if (cookies.isNotEmpty)
                  'Cookie':
                      cookies.map((c) => '${c.name}=${c.value}').join('; '),
              },
              extra: {
                'sensitive': true
              }));
      await _jar.saveFromResponse(
          uri,
          (response.headers['set-cookie'] ?? [])
              .map(Cookie.fromSetCookieValue)
              .toList());
      final status = response.statusCode;
      final location = response.headers.value('location');
      if ([301, 302, 303, 307, 308].contains(status) && location != null) {
        uri = uri.resolve(location);
        if ([301, 302, 303].contains(status)) {
          method = 'GET';
          body = null;
        }
        continue;
      }
      return response;
    }
    throw CoreError('斗鱼登录跳转次数过多');
  }

  Map<String, dynamic> _json(dynamic body) {
    if (body is Map) return Map<String, dynamic>.from(body);
    final text = '$body'.trim();
    final match = RegExp(r'^[\w$.]+\((\{[\s\S]*\})\);?$').firstMatch(text);
    try {
      final decoded =
          jsonDecode(text.startsWith('{') ? text : match?.group(1) ?? '');
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    throw CoreError('斗鱼登录响应无效');
  }

  Future<DouyuLoginChallenge> create() async {
    final response = await _request(
        Uri.parse('https://passport.douyu.com/scan/generateCode'),
        method: 'POST',
        body: 'client_id=1&isMultiAccount=0');
    final obj = _json(response.data);
    final data = obj['data'];
    if ('${obj['error']}' != '0' ||
        data is! Map ||
        data['code'] is! String ||
        (data['code'] as String).isEmpty) {
      throw CoreError('斗鱼二维码获取失败');
    }
    final qr = Uri.tryParse('${data['url']}');
    if (qr == null || !_allowed(qr)) throw CoreError('斗鱼二维码地址无效');
    _code = data['code'];
    final expiry = int.tryParse('${data['expire']}') ?? 0;
    return DouyuLoginChallenge(qr.toString(),
        expiry > 0 ? DateTime.now().add(Duration(seconds: expiry)) : null);
  }

  Future<DouyuLoginResult> poll() async {
    if (_code == null) throw CoreError('斗鱼二维码尚未获取');
    if (_busy) throw CoreError('斗鱼登录状态正在查询');
    _busy = true;
    try {
      final response = await _request(Uri.https(
          'passport.douyu.com', '/japi/scan/auth', {
        'time': '${DateTime.now().millisecondsSinceEpoch}',
        'code': _code!
      }));
      final obj = _json(response.data);
      switch ('${obj['error']}') {
        case '-1':
          return DouyuLoginResult(DouyuLoginState.expired);
        case '1':
          return DouyuLoginResult(DouyuLoginState.scanned);
        case '0':
          break;
        default:
          return DouyuLoginResult(DouyuLoginState.waiting);
      }
      final data = obj['data'];
      final callback = data is Map ? Uri.tryParse('${data['url']}') : null;
      if (callback == null || !_allowed(callback)) {
        throw CoreError('斗鱼登录回调地址无效');
      }
      final finish = await _request(callback.replace(queryParameters: {
        ...callback.queryParameters,
        if (!callback.queryParameters.containsKey('callback'))
          'callback': 'appClient_json_callback',
      }));
      if ('${_json(finish.data)['error']}' != '0') {
        return DouyuLoginResult(DouyuLoginState.failed);
      }
      final cookies = await _jar.loadForRequest(
          Uri.parse('https://www.douyu.com/lapi/live/getH5PlayV1/1'));
      final names = cookies.map((c) => c.name).toSet();
      if (!names.contains('acf_uid') ||
          !names.any((n) => ['acf_auth', 'acf_dmjwt_token'].contains(n))) {
        throw CoreError('斗鱼登录回调缺少凭据');
      }
      final cookie = cookies.map((c) => '${c.name}=${c.value}').join('; ');
      if (!await validateCookie(cookie, dio: _dio, cancelToken: _cancel)) {
        return DouyuLoginResult(DouyuLoginState.failed);
      }
      return DouyuLoginResult(DouyuLoginState.confirmed, cookie: cookie);
    } finally {
      _busy = false;
    }
  }

  /// A redirect to passport is expired. Do not follow it and mistake its 200
  /// login page response for a valid account.
  /// This checks the website account session, not playback authorization.
  static Future<bool> validateCookie(String cookie,
      {Dio? dio, CancelToken? cancelToken}) async {
    if (cookie.isEmpty) return false;
    final client = dio ??
        Dio(BaseOptions(
            connectTimeout: const Duration(seconds: 20),
            receiveTimeout: const Duration(seconds: 20)));
    try {
      final response = await client.get('https://www.douyu.com/member/login',
          cancelToken: cancelToken,
          options: Options(
              followRedirects: false,
              responseType: ResponseType.plain,
              validateStatus: (status) => status == 200 || status == 302,
              headers: {'User-Agent': _headers['User-Agent'], 'Cookie': cookie},
              extra: {'sensitive': true}));
      return response.statusCode == 200;
    } finally {
      if (dio == null) client.close();
    }
  }

  void close() {
    _cancel.cancel('login closed');
    if (_ownsDio) _dio.close(force: true);
  }
}
