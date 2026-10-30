import 'dart:convert';

class LivePlayUrl {
  /// 播放地址
  final List<String> urls;

  /// 请求头
  final Map<String, String>? headers;

  /// Per-route headers when the signature identity differs between CDNs.
  final List<Map<String, String>>? urlHeaders;

  Map<String, String>? headersFor(int index) =>
      urlHeaders != null && index >= 0 && index < urlHeaders!.length
          ? urlHeaders![index]
          : headers;

  LivePlayUrl({
    required this.urls,
    this.headers,
    this.urlHeaders,
  });

  @override
  String toString() {
    return json.encode({
      "urls": urls,
      "headers": headers.toString(),
    });
  }
}
