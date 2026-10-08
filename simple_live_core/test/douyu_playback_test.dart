import 'package:dio/dio.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/http_client.dart' as core_http;
import 'package:simple_live_core/src/douyu/douyu_playback_client.dart';
import 'package:test/test.dart';

void main() {
  // Golden outputs from the actual AngelLive 2.0.21 plugin, using Host.crypto.md5
  // and a fixed server Date. These cover its anonymous and logged-in branches.
  const fixtures = [
    [0, 0, '0dbe693c1b6b868901296edf2c308720'],
    [0, 1, 'd281d7b7ee69500599d6233c4ac2f4d8'],
    [1, 0, '69a302085e7152a467309ee8977c2a03'],
    [1, 1, '2d5c39125d3508e117dfdc75cd276c18'],
    [1000, 0, 'ed112b2f6407ba3b3150bba81cb01801'],
    [1000, 1, 'b3b8d91e6693ca06949d901267276fd5'],
  ];
  late Dio dio;
  late List<RequestOptions> requests;
  dynamic iterations;
  var special = 0;
  var serverDate = 'Tue, 06 Oct 2026 00:00:00 GMT';
  var error = 0;
  var failCdn = '';
  Map<String, dynamic> streamData() => {
        'rate': 4,
        'rtmp_url': 'https://cdn.test',
        'rtmp_live': 'live_4000.flv?a=1&amp;b=2',
        'multirates': [
          {'rate': 0, 'name': '原画1080P60'},
          {'rate': 4, 'name': '蓝光4M'}
        ],
        'cdnsWithName': [
          {'cdn': 'bad'},
          {'cdn': 'good'}
        ],
      };
  setUp(() {
    requests = [];
    iterations = 1;
    special = 0;
    serverDate = 'Tue, 06 Oct 2026 00:00:00 GMT';
    error = 0;
    failCdn = 'never';
    dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        requests.add(options);
        final isEncryption = options.uri.path.endsWith('getEncryption');
        final rejected =
            !isEncryption && (error != 0 || options.data['cdn'] == failCdn);
        handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            headers: Headers.fromMap({
              'date': [serverDate]
            }),
            data: {
              'error': rejected ? -9 : 0,
              'data': rejected
                  ? ''
                  : isEncryption
                      ? {
                          'key': 'test-key',
                          'rand_str': 'test-random',
                          'enc_data': 'encrypted',
                          'enc_time': iterations,
                          'is_special': special,
                        }
                      : streamData(),
            }));
      }));
  });
  tearDown(() => dio.close());
  DouyuPlaybackClient client() =>
      DouyuPlaybackClient(dio: dio, now: () => DateTime.utc(2020));

  for (final fixture in fixtures) {
    test(
        'AngelLive signature parity: iterations=${fixture[0]} special=${fixture[1]}',
        () async {
      iterations = fixture[0];
      special = fixture[1] as int;
      await client().fetch(
          roomId: '6979222',
          rate: 0,
          cdn: 'hw-h5',
          cookie: 'acf_auth=test-only');
      expect(requests, hasLength(2));
      expect(requests.first.uri.path, endsWith('/getEncryption'));
      expect(requests.last.uri.path, '/lapi/live/getH5PlayV1/6979222');
      expect(requests.last.data['tt'], '1791244800');
      expect(requests.last.data['auth'], fixture[2]);
      expect(requests.last.data['rate'], '0');
      expect(requests.last.data['cdn'], 'hw-h5');
      expect(requests.every((r) => r.headers['Cookie'] == 'acf_auth=test-only'),
          isTrue);
      expect(requests.every((r) => r.extra['sensitive'] == true), isTrue);
    });
  }
  for (final count in [-1, 10001, '1.5', '', null]) {
    test('rejects invalid encryption count $count before playback', () async {
      iterations = count;
      await expectLater(client().fetch(roomId: '6979222', rate: 0),
          throwsA(isA<CoreError>()));
      expect(requests, hasLength(1));
    });
  }
  test('invalid server Date falls back to local clock', () async {
    serverDate = 'invalid';
    failCdn = 'never';
    await client().fetch(roomId: '6979222', rate: 2);
    expect(requests.last.data['tt'], '1577836800');
    expect(requests.last.data['rate'], '2');
    expect(requests.every((r) => !r.headers.containsKey('Cookie')), isTrue);
  });
  test('both requests use the device from the login Cookie', () async {
    const device = '1234567890abcdef1234567890abcdef';
    await client().fetch(
        roomId: '6979222', rate: 0, cookie: 'acf_uid=123; dy_did=$device;');
    expect(requests.first.queryParameters['did'], device);
    expect(requests.last.data['did'], device);
  });
  test('integral JSON decimal count matches the plugin Number conversion',
      () async {
    iterations = 1.0;
    await client().fetch(roomId: '6979222', rate: 0);
    expect(requests.last.data['auth'], fixtures[2][2]);
  });
  test('invalid upstream JSON never appears in the error message', () async {
    final invalid = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (r, h) {
        h.resolve(
            Response(requestOptions: r, data: '<html>private-token</html>'));
      }));
    try {
      await expectLater(
          DouyuPlaybackClient(dio: invalid).fetch(roomId: '6979222', rate: 0),
          throwsA(isA<CoreError>().having((e) => e.message, 'safe message',
              isNot(contains('private-token')))));
    } finally {
      invalid.close();
    }
  });
  test('business rejection with string data reports CoreError', () async {
    error = -9;
    await expectLater(
        client().fetch(roomId: '6979222', rate: 0),
        throwsA(isA<CoreError>()
            .having((e) => e.message, 'message', contains('-9'))));
  });
  test('actual rate and playable headers preserve server downgrade', () {
    final stream = client().stream(streamData(), 0, 'hw-h5');
    expect(stream.url, 'https://cdn.test/live_4000.flv?a=1&b=2');
    expect(stream.downgraded, isTrue);
    expect(stream.actualQuality, '蓝光4M');
    final result = DouyuPlayUrl([stream]);
    expect(result.headers,
        {'User-Agent': 'libmpv', 'Referer': 'https://www.douyu.com/'});
    expect(
        () => client()
            .stream({...streamData(), 'rtmp_url': 'ftp://cdn.test'}, 0, ''),
        throwsA(isA<CoreError>()));
  });
  test('site refresh ignores stale room data and keeps working CDN', () async {
    CoreLog.enableLog = false;
    final original = core_http.HttpClient.instance.dio;
    core_http.HttpClient.instance.dio = dio;
    failCdn = 'bad';
    try {
      final site = DouyuSite()..cookie = 'acf_auth=test-only';
      final detail = LiveRoomDetail(
          roomId: '6979222',
          title: '',
          cover: '',
          userName: '',
          userAvatar: '',
          online: 0,
          status: true,
          url: '',
          data: 'expired-signature');
      final quality = LivePlayQuality(
          quality: '原画1080P60', data: DouyuPlayData(0, ['bad', 'good']));
      for (var i = 0; i < 2; i++) {
        final result = await site.getPlayUrls(detail: detail, quality: quality)
            as DouyuPlayUrl;
        expect(result.streams.single.cdn, 'good');
        expect(result.streams.single.actualRate, 4);
      }
      expect(requests.where((r) => r.uri.path.endsWith('getEncryption')),
          hasLength(4));
      expect(requests.every((r) => r.headers['Cookie'] == site.cookie), isTrue);
    } finally {
      core_http.HttpClient.instance.dio = original;
    }
  });
}
