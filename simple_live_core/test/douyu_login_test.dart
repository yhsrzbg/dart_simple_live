import 'package:dio/dio.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/core_error.dart';
import 'package:test/test.dart';

void main() {
  late Dio dio;
  late DouyuLoginClient client;
  late List<RequestOptions> requests;
  var pollCode = 0;
  var callback = 'https://passport.douyu.com/finish';
  var loginStatus = 200;
  var completionError = 0;
  setUp(() {
    requests = [];
    pollCode = 0;
    callback = 'https://passport.douyu.com/finish';
    loginStatus = 200;
    completionError = 0;
    dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (r, h) {
        requests.add(r);
        dynamic data;
        var status = 200;
        final headers = <String, List<String>>{};
        switch (r.uri.path) {
          case '/scan/generateCode':
            data = {
              'error': 0,
              'data': {
                'code': 'qr-key',
                'url': 'https://passport.douyu.com/scan/qr-key',
                'expire': 120
              }
            };
            headers['set-cookie'] = [
              'scan_session=one; Path=/; Secure; HttpOnly'
            ];
            break;
          case '/japi/scan/auth':
            data = {
              'error': pollCode,
              'data': {'url': callback}
            };
            break;
          case '/finish':
            status = 302;
            data = '';
            headers['set-cookie'] = [
              'acf_auth=secret-test; Domain=.douyu.com; Path=/; Secure; HttpOnly'
            ];
            headers['location'] = ['https://www.douyu.com/complete'];
            break;
          case '/complete':
            headers['set-cookie'] = [
              'acf_uid=123; Domain=.douyu.com; Path=/; Secure',
              'path_only=no; Domain=.douyu.com; Path=/private; Secure',
              'expired=no; Domain=.douyu.com; Path=/; Max-Age=0',
            ];
            data = 'appClient_json_callback({"error":$completionError});';
            break;
          case '/member/login':
            status = loginStatus;
            data = '';
            headers['location'] = ['https://passport.douyu.com/member/login'];
            break;
          default:
            fail('Unexpected path ${r.uri.path}');
        }
        h.resolve(Response(
            requestOptions: r,
            statusCode: status,
            data: data,
            headers: Headers.fromMap(headers)));
      }));
    client = DouyuLoginClient(dio: dio);
  });
  tearDown(() {
    client.close();
    dio.close();
  });

  test('QR callback merges HttpOnly cookies through redirects by scope',
      () async {
    final qr = await client.create();
    expect(qr.qrContent, 'https://passport.douyu.com/scan/qr-key');
    expect(qr.expiresAt, isNotNull);
    final result = await client.poll();
    expect(result.state, DouyuLoginState.confirmed);
    expect(result.cookie, contains('acf_auth=secret-test'));
    expect(result.cookie, contains('acf_uid=123'));
    expect(result.cookie, isNot(contains('scan_session')));
    expect(result.cookie, isNot(contains('path_only')));
    expect(result.cookie, isNot(contains('expired')));
    expect(requests[1].headers['Cookie'], 'scan_session=one');
    expect(
        requests[2].uri.queryParameters['callback'], 'appClient_json_callback');
    expect(requests[3].headers['Cookie'], contains('acf_auth=secret-test'));
    expect(requests[3].headers['Cookie'], isNot(contains('scan_session')));
    expect(
        requests.every(
            (r) => r.followRedirects == false && r.extra['sensitive'] == true),
        isTrue);
  });
  for (final entry in <int, DouyuLoginState>{
    -1: DouyuLoginState.expired,
    1: DouyuLoginState.scanned,
    2: DouyuLoginState.waiting
  }.entries) {
    test('poll state ${entry.key} does not visit callback', () async {
      pollCode = entry.key;
      await client.create();
      final result = await client.poll();
      expect(result.state, entry.value);
      expect(result.cookie, isNull);
      expect(requests, hasLength(2));
    });
  }
  for (final url in [
    'https://douyu.com.evil.test/finish',
    'http://www.douyu.com/finish'
  ]) {
    test('rejects foreign or insecure callback $url', () async {
      callback = url;
      await client.create();
      await expectLater(client.poll(), throwsA(isA<CoreError>()));
      expect(requests, hasLength(2));
    });
  }
  test('redirected login check is rejected without visiting login page',
      () async {
    loginStatus = 302;
    expect(await DouyuLoginClient.validateCookie('acf_auth=test', dio: dio),
        isFalse);
    expect(requests, hasLength(1));
    expect(requests.single.followRedirects, isFalse);
  });
  test('failed callback never exports credentials', () async {
    completionError = 1;
    await client.create();
    final result = await client.poll();
    expect(result.state, DouyuLoginState.failed);
    expect(result.cookie, isNull);
  });
  test('closing session cancels subsequent requests', () async {
    await client.create();
    client.close();
    await expectLater(
        client.poll(),
        throwsA(isA<DioException>()
            .having((e) => e.type, 'type', DioExceptionType.cancel)));
  });
}
