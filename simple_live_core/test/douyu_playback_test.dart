import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/http_client.dart' as core_http;
import 'package:simple_live_core/src/douyu/douyu_playback_client.dart';
import 'package:test/test.dart';

void main() {
  String token(int expiry) => 'e30.${base64Url.encode(utf8.encode(jsonEncode({
            'exp': expiry
          }))).replaceAll('=', '')}.test';
  final validCookie = 'acf_auth=test-only; acf_jwt_token=${token(2000000000)}';
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
  String? rejectSessionAt;
  var rejectStatus = 200;
  var guestAlsoRejected = false;
  var encryptionSequence = 0;
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
    rejectSessionAt = null;
    rejectStatus = 200;
    guestAlsoRejected = false;
    encryptionSequence = 0;
    dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        requests.add(options);
        final isEncryption = options.uri.path.endsWith('getEncryption');
        if (isEncryption) encryptionSequence++;
        if ((options.headers.containsKey('Cookie') || guestAlsoRejected) &&
            options.uri.path.endsWith(rejectSessionAt ?? 'never')) {
          handler.resolve(Response(
              requestOptions: options,
              statusCode: rejectStatus,
              headers: Headers.fromMap(rejectStatus == 302
                  ? {
                      'location': ['https://passport.douyu.com/member/login']
                    }
                  : {}),
              data: {'error': -9, 'data': ''}));
          return;
        }
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
                          'enc_data': 'encrypted-$encryptionSequence',
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

  test('incomplete playback credentials go directly to guest mode', () async {
    for (final cookie in ['acf_auth=old', 'acf_jwt_token=malformed']) {
      requests.clear();
      await client().fetch(roomId: '6979222', rate: 0, cookie: cookie);
      expect(requests, hasLength(2));
      expect(requests.every((r) => !r.headers.containsKey('Cookie')), isTrue);
    }
  });
  test('JWT expiry uses server time and restarts with guest DID and signature',
      () async {
    // Device clock is 2020; JWT expired in 2023 according to server Date.
    await client().fetch(
        roomId: '6979222',
        rate: 4,
        cdn: 'good',
        cookie:
            'acf_auth=old; acf_jwt_token=${token(1700000000)}; acf_did=abcdefghijklmnop');
    expect(requests, hasLength(3));
    expect(requests.first.queryParameters['did'], 'abcdefghijklmnop');
    expect(requests[1].queryParameters['did'], DouyuPlaybackClient.did);
    expect(requests.last.data['enc_data'], 'encrypted-2');
    expect(requests.last.data['did'], DouyuPlaybackClient.did);
    expect(requests.last.data['rate'], '4');
    expect(requests.last.data['cdn'], 'good');
    expect(requests.skip(1).every((r) => !r.headers.containsKey('Cookie')),
        isTrue);
  });
  for (final endpoint in ['getEncryption', 'getH5PlayV1/6979222']) {
    for (final status in [200, 401, 403, 302]) {
      test('session rejection at $endpoint HTTP $status retries guest once',
          () async {
        rejectSessionAt = endpoint;
        rejectStatus = status;
        await client().fetch(roomId: '6979222', rate: 0, cookie: validCookie);
        final sessionRequests = endpoint == 'getEncryption' ? 1 : 2;
        expect(requests, hasLength(sessionRequests + 2));
        expect(
            requests
                .skip(sessionRequests)
                .every((r) => !r.headers.containsKey('Cookie')),
            isTrue);
        expect(requests.last.data['enc_data'], 'encrypted-2');
        // No sticky guest state: renewed credentials are used on the next call.
        rejectSessionAt = null;
        requests.clear();
        await client().fetch(roomId: '6979222', rate: 0, cookie: validCookie);
        expect(
            requests.every((r) => r.headers['Cookie'] == validCookie), isTrue);
      });
    }
  }
  test('guest rejection terminates without a retry loop', () async {
    rejectSessionAt = 'getH5PlayV1/6979222';
    guestAlsoRejected = true;
    await expectLater(
        client().fetch(roomId: '6979222', rate: 0, cookie: validCookie),
        throwsA(isA<CoreError>()));
    expect(requests, hasLength(4));
  });
  test('server outage does not cause a guest retry', () async {
    rejectSessionAt = 'getEncryption';
    rejectStatus = 503;
    await expectLater(
        client().fetch(roomId: '6979222', rate: 0, cookie: validCookie),
        throwsA(isA<CoreError>()));
    expect(requests, hasLength(1));
  });
  test('acf_did takes priority and supports the upstream device format',
      () async {
    await client().fetch(
        roomId: '6979222',
        rate: 0,
        cookie:
            '$validCookie; acf_did=abcdefghijklmnop; dy_did=1234567890abcdef1234567890abcdef');
    expect(requests.first.queryParameters['did'], 'abcdefghijklmnop');
    expect(requests.last.data['did'], 'abcdefghijklmnop');
  });
  test('unconfirmed quality preserves a playable URL and requested rate', () {
    for (final rate in [null, '', 'invalid', -1, 1.5, 9007199254740992]) {
      final stream =
          client().stream({...streamData(), 'rate': rate}, 4, 'good');
      expect(stream.url, startsWith('https://cdn.test/'));
      expect(stream.requestedRate, 4);
      expect(stream.actualRate, -1);
      expect(stream.actualQuality, '清晰度未确认');
      expect(stream.downgraded, isFalse);
    }
  });

  for (final fixture in fixtures) {
    test(
        'AngelLive signature parity: iterations=${fixture[0]} special=${fixture[1]}',
        () async {
      iterations = fixture[0];
      special = fixture[1] as int;
      await client()
          .fetch(roomId: '6979222', rate: 0, cdn: 'hw-h5', cookie: validCookie);
      expect(requests, hasLength(2));
      expect(requests.first.uri.path, endsWith('/getEncryption'));
      expect(requests.last.uri.path, '/lapi/live/getH5PlayV1/6979222');
      expect(requests.last.data['tt'], '1791244800');
      expect(requests.last.data['auth'], fixture[2]);
      expect(requests.last.data['rate'], '0');
      expect(requests.last.data['cdn'], 'hw-h5');
      expect(requests.every((r) => r.headers['Cookie'] == validCookie), isTrue);
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
        h.resolve(Response(
            requestOptions: r,
            statusCode: 200,
            data: '<html>private-token</html>'));
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
      final site = DouyuSite()..cookie = validCookie;
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
          hasLength(6));
      expect(site.cookie, validCookie);
      expect(
          requests.where((r) => r.headers.containsKey('Cookie')), hasLength(8));
    } finally {
      core_http.HttpClient.instance.dio = original;
    }
  });
}
