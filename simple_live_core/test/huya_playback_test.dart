import 'dart:async';
import 'dart:convert';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/core_error.dart';
import 'package:test/test.dart';

class ProbeHuya extends HuyaSite {
  Future<String> Function(String, String)? token;
  @override
  Future<String> getCndTokenInfoEx(String stream, {String flvUrl = ''}) =>
      token!(stream, flvUrl);
}

void main() {
  late ProbeHuya site;
  String token(String ctype, {String? time}) => Uri(queryParameters: {
        'fm': base64.encode(utf8.encode('prefix_\$0_\$1_\$2_\$3')),
        'ctype': ctype,
        'fs': '1',
        'wsTime': time ??
            (DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600)
                .toRadixString(16),
      }).query;
  HuyaLineModel line(String name, {String fallback = ''}) => HuyaLineModel(
      line: 'https://$name.test',
      lineType: HuyaLineType.flv,
      flvAntiCode: fallback,
      hlsAntiCode: '',
      streamName: name,
      cdnType: name,
      presenterUid: 123456);
  final detail = LiveRoomDetail(
      roomId: '123',
      title: '',
      cover: '',
      userName: '',
      userAvatar: '',
      online: 0,
      status: true,
      url: '');
  Future<LivePlayUrl> fetch(List<HuyaLineModel> lines) => site.getPlayUrls(
      detail: detail,
      quality: LivePlayQuality(
          quality: '超清', data: {'urls': lines, 'bitRate': 4000}));
  setUp(() {
    CoreLog.enableLog = false;
    site = ProbeHuya();
  });
  tearDown(() => site.tupClient.dio.close(force: true));

  test('WUP uses bounded millisecond connect, receive and send timeouts', () {
    expect(
        site.tupClient.dio.options.connectTimeout, const Duration(seconds: 20));
    expect(
        site.tupClient.dio.options.receiveTimeout, const Duration(seconds: 20));
    expect(site.tupClient.dio.options.sendTimeout, const Duration(seconds: 20));
  });
  test('platform is inferred from ctype when t is missing', () {
    final signed = Uri.splitQueryString(
        site.buildAntiCode('stream', 123, token('tars_mobile')));
    expect(signed['t'], '103');
    expect(signed['uid'], '123');
    expect(signed.containsKey('u'), isFalse);
    final pc = Uri.splitQueryString(
        site.buildAntiCode('stream', 123, token('huya_pc_exe')));
    expect(pc['t'], '0');
    expect(pc.containsKey('u'), isTrue);
  });
  test('near-expiry anticode is renewed before calculating its signature', () {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final signed = Uri.splitQueryString(site.buildAntiCode('stream', 123,
        token('tars_mobile', time: (now + 10).toRadixString(16))));
    expect(
        int.parse(signed['wsTime']!, radix: 16), greaterThan(now + 23 * 3600));
    expect(signed['wsSecret'], matches(RegExp(r'^[a-f0-9]{32}$')));
  });
  test(
      'one failed CDN does not discard good lines and headers match each signature',
      () async {
    site.token = (name, host) async {
      expect(host, 'https://$name.test');
      if (name != 'pc') throw StateError('WUP unavailable');
      return token('huya_pc_exe');
    };
    final result = await fetch([
      line('bad'),
      line('mobile', fallback: token('tars_mobile')),
      line('pc')
    ]);
    expect(result.urls, hasLength(2));
    expect(result.urls.first, startsWith('https://mobile.test/'));
    expect(
        result.headersFor(0)!['user-agent'], HuyaSite.mobilePlaybackUserAgent);
    expect(result.headersFor(1)!['user-agent'], HuyaSite.HYSDK_UA);
    expect(Uri.parse(result.urls.first).queryParameters['ratio'], '4000');
  });
  test('concurrency is bounded to three and result order follows the input',
      () async {
    var active = 0;
    var peak = 0;
    site.token = (name, _) async {
      active++;
      if (active > peak) peak = active;
      await Future<void>.delayed(Duration(milliseconds: name == 'a' ? 20 : 1));
      active--;
      return token('huya_pc_exe');
    };
    final result =
        await fetch(['a', 'b', 'c', 'd', 'e'].map((s) => line(s)).toList());
    expect(peak, 3);
    expect(result.urls.map((u) => Uri.parse(u).host),
        ['a.test', 'b.test', 'c.test', 'd.test', 'e.test']);
  });
  test('all failed lines report a bounded platform error', () async {
    site.token = (_, __) async => throw StateError('failed');
    await expectLater(fetch([line('bad')]), throwsA(isA<CoreError>()));
  });
}
