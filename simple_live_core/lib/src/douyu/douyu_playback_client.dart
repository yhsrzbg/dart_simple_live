import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:html_unescape/html_unescape.dart';
import '../common/core_error.dart';
import '../common/http_client.dart';
import '../model/live_play_url.dart';
import 'douyu_session.dart';

/// Douyu web playback with the session fallback used by AngelLive 2.0.25.
class DouyuPlaybackClient {
  DouyuPlaybackClient({Dio? dio, DateTime Function()? now})
      : _dio = dio ?? HttpClient.instance.dio,
        _now = now ?? DateTime.now;

  final Dio _dio;
  final DateTime Function() _now;
  static const did = DouyuSession.guestDevice;
  static const userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 Edg/114.0.1823.43';
  static const playbackHeaders = {
    'User-Agent': 'libmpv',
    'Referer': 'https://www.douyu.com/',
  };

  Map<String, dynamic> _payload(
      Response<dynamic> response, String operation, bool authenticated) {
    final status = response.statusCode ?? 0;
    final loginRedirect = response.realUri.host == 'passport.douyu.com' ||
        (response.headers.value('location') ?? '')
            .startsWith('https://passport.douyu.com/member/login');
    if (status != 200 || loginRedirect) {
      if (authenticated && (status == 401 || status == 403 || loginRedirect)) {
        throw _RetryAsGuest();
      }
      throw CoreError('斗鱼$operation失败（HTTP $status）');
    }
    dynamic decoded;
    try {
      decoded =
          response.data is String ? jsonDecode(response.data) : response.data;
    } catch (_) {
      throw CoreError('斗鱼$operation响应无效');
    }
    final code = decoded is Map ? num.tryParse('${decoded['error']}') : null;
    if (code == null || !code.isFinite || code != 0) {
      if (authenticated && code != null && code.isFinite && code != 0) {
        throw _RetryAsGuest();
      }
      throw CoreError(
          '斗鱼$operation失败（${code != null && code.isFinite ? code : 'invalid'}）');
    }
    final data = decoded['data'];
    if (data is! Map) throw CoreError('斗鱼$operation数据无效');
    return Map<String, dynamic>.from(data);
  }

  Future<Map<String, dynamic>> fetch({
    required String roomId,
    required int rate,
    String cdn = '',
    String cookie = '',
  }) async {
    if (!RegExp(r'^\d+$').hasMatch(roomId)) throw CoreError('斗鱼房间号无效');
    final session = DouyuSession(cookie);
    final incomplete = session.hasCredential && session.playbackExpiry == null;
    try {
      return await _fetch(roomId, rate, cdn, incomplete ? '' : cookie);
    } on _RetryAsGuest {
      // Start a fresh guest signature transaction, retaining the saved Cookie.
      return _fetch(roomId, rate, cdn, '');
    }
  }

  Future<Map<String, dynamic>> _fetch(
      String roomId, int rate, String cdn, String cookie) async {
    final session = DouyuSession(cookie);
    final authenticated = cookie.isNotEmpty;
    final device = session.device;
    final headers = <String, String>{
      'User-Agent': userAgent,
      'Referer': 'https://www.douyu.com/',
      if (cookie.isNotEmpty) 'Cookie': cookie,
    };
    final encrypted = await _dio.get(
      'https://www.douyu.com/wgapi/livenc/liveweb/websec/getEncryption',
      queryParameters: {'did': device},
      options: Options(
          headers: headers,
          extra: {'sensitive': true},
          followRedirects: false,
          validateStatus: (_) => true),
    );
    final data = _payload(encrypted, '签名参数获取', authenticated);
    final timestamp = DouyuSession.responseTime(encrypted, _now());
    if (session.hasCredential && !session.canPlay(timestamp)) {
      throw _RetryAsGuest();
    }
    final numericCount = num.tryParse('${data['enc_time']}');
    if (numericCount == null ||
        !numericCount.isFinite ||
        numericCount < 0 ||
        numericCount > 10000 ||
        numericCount != numericCount.truncateToDouble()) {
      throw CoreError('斗鱼签名轮数无效');
    }
    final count = numericCount.toInt();
    for (final field in ['key', 'rand_str', 'enc_data']) {
      if (data[field] is! String || (data[field] as String).isEmpty) {
        throw CoreError('斗鱼签名参数无效');
      }
    }
    String hash(String value) => md5.convert(utf8.encode(value)).toString();
    var value = data['rand_str'] as String;
    final key = data['key'] as String;
    for (var i = 0; i < count; i++) {
      value = hash(value + key);
    }
    final suffix = '${data['is_special']}' == '1' ? '' : '$roomId$timestamp';
    final result = await _dio.post(
      'https://www.douyu.com/lapi/live/getH5PlayV1/$roomId',
      data: {
        'enc_data': data['enc_data'],
        'tt': '$timestamp',
        'did': device,
        'auth': hash(value + key + suffix),
        'cdn': cdn,
        'rate': '$rate',
        'hevc': '0',
        'fa': '0',
        'ive': '0',
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        headers: {...headers, 'Referer': 'https://www.douyu.com/$roomId'},
        extra: {'sensitive': true},
        followRedirects: false,
        validateStatus: (_) => true,
      ),
    );
    return _payload(result, '取流', authenticated);
  }

  DouyuStream stream(Map<String, dynamic> data, int rate, String cdn) {
    final host = data['rtmp_url'];
    final live = data['rtmp_live'];
    if (host is! String || host.isEmpty || live is! String || live.isEmpty) {
      throw CoreError('斗鱼播放地址无效');
    }
    final url = '$host/${HtmlUnescape().convert(live)}';
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !uri.hasAuthority ||
        !['http', 'https'].contains(uri.scheme)) {
      throw CoreError('斗鱼播放地址无效');
    }
    final text = '${data['rate']}'.trim();
    final parsedRate =
        RegExp(r'^\d+$').hasMatch(text) ? int.tryParse(text) ?? -1 : -1;
    final actualRate = parsedRate <= 9007199254740991 ? parsedRate : -1;
    var actualQuality = actualRate < 0 ? '清晰度未确认' : '清晰度 $actualRate';
    if (actualRate >= 0 && data['multirates'] is List) {
      for (final item in data['multirates']) {
        if (item is Map && '${item['rate']}' == '$actualRate') {
          actualQuality = '${item['name']}';
          break;
        }
      }
    }
    return DouyuStream(
        url: url,
        cdn: cdn,
        requestedRate: rate,
        actualRate: actualRate,
        actualQuality: actualQuality);
  }
}

class DouyuStream {
  final String url;
  final String cdn;
  final int requestedRate;
  final int actualRate;
  final String actualQuality;
  bool get downgraded => actualRate >= 0 && requestedRate != actualRate;
  DouyuStream(
      {required this.url,
      required this.cdn,
      required this.requestedRate,
      required this.actualRate,
      required this.actualQuality});
}

class _RetryAsGuest implements Exception {}

class DouyuPlayUrl extends LivePlayUrl {
  final List<DouyuStream> streams;
  DouyuPlayUrl(this.streams)
      : super(
            urls: streams.map((item) => item.url).toList(),
            headers: DouyuPlaybackClient.playbackHeaders);
}
