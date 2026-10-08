import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:html_unescape/html_unescape.dart';
import '../common/core_error.dart';
import '../common/http_client.dart';
import '../model/live_play_url.dart';

/// Douyu's current web playback protocol, also used by AngelLive 2.0.21.
class DouyuPlaybackClient {
  DouyuPlaybackClient({Dio? dio, DateTime Function()? now})
      : _dio = dio ?? HttpClient.instance.dio,
        _now = now ?? DateTime.now;

  final Dio _dio;
  final DateTime Function() _now;
  static const did = '10000000000000000000000000001501';
  static const userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 Edg/114.0.1823.43';
  static const playbackHeaders = {
    'User-Agent': 'libmpv',
    'Referer': 'https://www.douyu.com/',
  };

  Map<String, dynamic> _payload(dynamic response, String operation) {
    dynamic decoded;
    try {
      decoded = response is String ? jsonDecode(response) : response;
    } catch (_) {
      throw CoreError('斗鱼$operation响应无效');
    }
    if (decoded is! Map || decoded['error'].toString() != '0') {
      final code = decoded is Map ? decoded['error'] : 'invalid';
      throw CoreError('斗鱼$operation失败（$code）');
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
    // The official web client uses the device from the same login session.
    final device = RegExp(r'(?:^|;\s*)dy_did=([a-fA-F0-9]{32})(?:;|$)')
            .firstMatch(cookie)
            ?.group(1) ??
        did;
    final headers = <String, String>{
      'User-Agent': userAgent,
      'Referer': 'https://www.douyu.com/',
      if (cookie.isNotEmpty) 'Cookie': cookie,
    };
    final encrypted = await _dio.get(
      'https://www.douyu.com/wgapi/livenc/liveweb/websec/getEncryption',
      queryParameters: {'did': device},
      options: Options(headers: headers, extra: {'sensitive': true}),
    );
    final data = _payload(encrypted.data, '签名参数获取');
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
    var timestamp = _now().millisecondsSinceEpoch ~/ 1000;
    try {
      final date = encrypted.headers.value('date');
      if (date != null) {
        timestamp = HttpDate.parse(date).millisecondsSinceEpoch ~/ 1000;
      }
    } catch (_) {
      // Same fallback as the plugin when the server Date is unavailable.
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
      ),
    );
    return _payload(result.data, '取流');
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
    final actualRate = int.tryParse('${data['rate']}');
    if (actualRate == null) throw CoreError('斗鱼实际清晰度无效');
    var actualQuality = '清晰度 $actualRate';
    if (data['multirates'] is List) {
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
  bool get downgraded => requestedRate != actualRate;
  DouyuStream(
      {required this.url,
      required this.cdn,
      required this.requestedRate,
      required this.actualRate,
      required this.actualQuality});
}

class DouyuPlayUrl extends LivePlayUrl {
  final List<DouyuStream> streams;
  DouyuPlayUrl(this.streams)
      : super(
            urls: streams.map((item) => item.url).toList(),
            headers: DouyuPlaybackClient.playbackHeaders);
}
