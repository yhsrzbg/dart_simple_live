import 'package:dio/dio.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/core_error.dart';
import 'package:test/test.dart';

void main() {
  late Dio dio;
  late BiliBiliLoginClient client;
  late List<RequestOptions> requests;
  dynamic account;
  var status = 200;
  var poll = 0;
  var returnSession = true;
  setUp(() {
    requests = [];
    status = 200;
    poll = 0;
    returnSession = true;
    account = {
      'code': 0,
      'data': {'isLogin': true, 'mid': 123, 'uname': '测试'}
    };
    dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (r, h) {
        requests.add(r);
        dynamic data;
        final headers = <String, List<String>>{};
        var httpStatus = 200;
        switch (r.uri.path) {
          case '/x/frontend/finger/spi':
            data = {
              'code': 0,
              'data': {'b_3': 'three', 'b_4': 'four'}
            };
            break;
          case '/x/passport-login/web/qrcode/generate':
            data = {
              'code': 0,
              'data': {
                'qrcode_key': 'test-qr-key',
                'url': 'https://passport.bilibili.com/qr'
              }
            };
            headers['set-cookie'] = ['scan_only=one; Path=/; Secure; HttpOnly'];
            break;
          case '/x/passport-login/web/qrcode/poll':
            data = {
              'code': 0,
              'data': {'code': poll}
            };
            if (returnSession && poll == 0) {
              headers['set-cookie'] = [
                'SESSDATA=secret; Domain=.bilibili.com; Path=/; Secure; HttpOnly',
                'DedeUserID=123; Domain=.bilibili.com; Path=/; Secure',
              ];
            }
            break;
          case '/x/web-interface/nav':
            httpStatus = status;
            data = !returnSession &&
                    requests.any((r) => r.uri.path.endsWith('/poll'))
                ? {'code': -101}
                : account;
            break;
          default:
            fail('Unexpected ${r.uri.path}');
        }
        h.resolve(Response(
            requestOptions: r,
            statusCode: httpStatus,
            data: data,
            headers: Headers.fromMap(headers)));
      }));
    client = BiliBiliLoginClient(dio: dio);
  });
  tearDown(() {
    client.close();
    dio.close();
  });

  test(
      'QR transaction preserves device and HttpOnly session cookies before confirmation',
      () async {
    expect(await client.create(), 'https://passport.bilibili.com/qr');
    final result = await client.poll();
    expect(result.state, BiliBiliLoginState.confirmed);
    expect(result.cookie, contains('buvid3=three'));
    expect(result.cookie, contains('buvid4=four'));
    expect(result.cookie, contains('SESSDATA=secret'));
    expect(result.cookie, isNot(contains('scan_only')));
    expect(requests[1].headers['Cookie'], contains('buvid3=three'));
    expect(requests[2].headers['Cookie'], contains('scan_only=one'));
    expect(requests.every((r) => r.extra['sensitive'] == true), isTrue);
    expect(requests.last.uri.path, '/x/web-interface/nav');
  });
  for (final entry in {
    86101: BiliBiliLoginState.waiting,
    86090: BiliBiliLoginState.scanned,
    86038: BiliBiliLoginState.expired,
    999: BiliBiliLoginState.failed
  }.entries) {
    test('poll ${entry.key} does not validate or export a session', () async {
      poll = entry.key;
      await client.create();
      final result = await client.poll();
      expect(result.state, entry.value);
      expect(result.cookie, isNull);
      expect(requests, hasLength(3));
    });
  }
  test('QR success without a usable session never confirms login', () async {
    returnSession = false;
    await client.create();
    expect((await client.poll()).state, BiliBiliLoginState.failed);
  });
  test(
      'account validation distinguishes valid, expired, risk control, and unavailable',
      () async {
    Future<BiliBiliAccountResult> check() =>
        BiliBiliLoginClient.checkAccount('SESSDATA=test', dio: dio);
    final valid = await check();
    expect(valid.state, BiliBiliAccountState.valid);
    expect(valid.uid, 123);
    for (final code in [-352, -101, -500]) {
      account = {'code': code};
      expect(
          (await check()).state,
          code == -352
              ? BiliBiliAccountState.riskControl
              : code == -101
                  ? BiliBiliAccountState.expired
                  : BiliBiliAccountState.unavailable);
    }
    status = 412;
    expect((await check()).state, BiliBiliAccountState.riskControl);
    status = 503;
    expect((await check()).state, BiliBiliAccountState.unavailable);
    status = 200;
    account = {
      'code': 0,
      'data': {'isLogin': true}
    };
    expect((await check()).state, BiliBiliAccountState.unavailable);
    account = '<html>secret-token</html>';
    await expectLater(
        check(),
        throwsA(isA<CoreError>().having(
            (e) => e.message, 'safe error', isNot(contains('secret-token')))));
  });
}
