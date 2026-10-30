import 'dart:async';
import 'package:dio/dio.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:test/test.dart';

void main() {
  late Dio original;
  late Dio dio;
  late BiliBiliSite site;
  late List<RequestOptions> requests;
  dynamic currentQn;
  var apiCode = 0;
  dynamic danmakuPort;
  late Map<String, dynamic> playurl;
  final detail = LiveRoomDetail(
      roomId: '123',
      title: '',
      cover: '',
      userName: '',
      userAvatar: '',
      online: 0,
      status: true,
      url: '');
  setUp(() {
    CoreLog.enableLog = false;
    original = HttpClient.instance.dio;
    site = BiliBiliSite();
    requests = [];
    currentQn = 400;
    apiCode = 0;
    danmakuPort = 2245;
    Map<String, dynamic> codec() => {
          'current_qn': currentQn,
          'accept_qn': [10000, 400],
          'base_url': '/live.flv',
          'url_info': [
            {'host': 'https://a.mcdn.test', 'extra': '?token=1'},
            {'host': 'https://good.test', 'extra': '?token=1'},
            {'host': 'https://good.test', 'extra': '?token=1'},
          ]
        };
    playurl = {
      'g_qn_desc': [
        {'qn': 10000, 'desc': '原画'},
        {'qn': 400, 'desc': '蓝光'}
      ],
      'stream': [
        {
          'format': [
            {
              'codec': [codec()]
            },
            {
              'codec': [
                {
                  'accept_qn': [250, 400]
                }
              ]
            }
          ]
        }
      ]
    };
    dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (r, h) {
        requests.add(r);
        if (r.uri.path.endsWith('/getDanmuInfo')) {
          h.resolve(Response(requestOptions: r, statusCode: 200, data: {
            'code': 0,
            'data': {
              'token': 'test-token',
              'host_list': [
                {'host': 'chat.test', 'wss_port': danmakuPort}
              ]
            }
          }));
          return;
        }
        h.resolve(Response(
            requestOptions: r,
            statusCode: 200,
            data: r.uri.path.endsWith('/spi')
                ? {
                    'code': 0,
                    'data': {'b_3': 'device-three', 'b_4': 'device-four'}
                  }
                : {
                    'code': apiCode,
                    'data': apiCode == 0
                        ? {
                            'playurl_info': {'playurl': playurl}
                          }
                        : null
                  }));
      }));
    HttpClient.instance.dio = dio;
  });
  tearDown(() {
    HttpClient.instance.dio = original;
    dio.close();
  });

  test(
      'fills each missing device cookie and parses a final field without semicolon',
      () async {
    site.cookie = 'SESSDATA=secret=a; buvid3=existing';
    final headers = await site.getHeader();
    expect(headers['cookie'],
        'SESSDATA=secret=a; buvid3=existing; buvid4=device-four');
    expect(site.buvid3, 'existing');
    expect(site.buvid4, 'device-four');
    await site.getHeader();
    expect(requests, hasLength(1));
  });
  test('preserves existing buvid4 while filling buvid3', () async {
    site.cookie = 'buvid4=existing-four; SESSDATA=secret';
    final headers = await site.getHeader();
    expect(headers['cookie'], contains('buvid4=existing-four'));
    expect(headers['cookie'], contains('buvid3=device-three'));
  });
  test('cookie changes invalidate device and access ID caches', () async {
    site.cookie = 'buvid3=old; buvid4=old-four';
    await site.getHeader();
    site.accessId = 'old-access';
    site.cookie = 'SESSDATA=new';
    expect(site.accessId, isEmpty);
    final headers = await site.getHeader();
    expect(headers['cookie'], isNot(contains('old')));
    expect(headers['cookie'], contains('SESSDATA=new'));
  });
  test('concurrent device lookups share one request', () async {
    await Future.wait([site.getHeader(), site.getHeader(), site.getHeader()]);
    expect(requests, hasLength(1));
  });
  test('danmaku keeps the API port, login UID, and parsed buvid', () async {
    site = DanmakuSite()
      ..cookie = 'SESSDATA=test; buvid3=existing; buvid4=four'
      ..userId = 123;
    final detail = await site.getRoomDetail(roomId: '123');
    final args = detail.danmakuData as BiliBiliDanmakuArgs;
    expect(args.serverPort, 2245);
    expect(args.serverHost, 'chat.test');
    expect(args.uid, 123);
    expect(args.buvid, 'existing');
    expect(args.toString(), isNot(contains('SESSDATA=test')));
  });
  test('danmaku invalid port falls back to HTTPS default', () async {
    site = DanmakuSite();
    danmakuPort = 0;
    final detail = await site.getRoomDetail(roomId: '123');
    expect((detail.danmakuData as BiliBiliDanmakuArgs).serverPort, 443);
  });
  test('late device lookup cannot inject the old account after logout',
      () async {
    final gate = Completer<Map>();
    site = DelayedDeviceSite(gate);
    site.cookie = 'SESSDATA=old';
    final pending = site.getHeader();
    site.cookie = 'buvid3=new; buvid4=new-four';
    gate.complete({'b_3': 'old-three', 'b_4': 'old-four'});
    final headers = await pending;
    expect(headers['cookie'], 'buvid3=new; buvid4=new-four');
    expect(site.buvid3, 'new');
  });
  test('collects and sorts quality menu across all stream formats', () async {
    final qualities = await site.getPlayQualites(detail: detail);
    expect(qualities.map((q) => q.data), [10000, 400, 250]);
  });
  test('reports actual downgrade, deduplicates URLs, and leaves mcdn last',
      () async {
    final result = await site.getPlayUrls(
            detail: detail,
            quality: LivePlayQuality(quality: '原画', data: 10000))
        as BiliBiliPlayUrl;
    expect(result.urls, [
      'https://good.test/live.flv?token=1',
      'https://a.mcdn.test/live.flv?token=1'
    ]);
    expect(result.streams.first.actualQn, 400);
    expect(result.streams.first.requestedQn, 10000);
    expect(result.streams.first.actualQuality, '蓝光');
    expect(result.streams.first.downgraded, isTrue);
    expect(requests.last.queryParameters['qn'], 10000);
  });
  test(
      'missing actual qn preserves playback without claiming requested quality',
      () async {
    playurl['stream'][0]['format'][0]['codec'][0].remove('current_qn');
    final result = await site.getPlayUrls(
            detail: detail,
            quality: LivePlayQuality(quality: '原画', data: 10000))
        as BiliBiliPlayUrl;
    expect(result.streams.first.actualQuality, '清晰度未确认');
    expect(result.streams.first.downgraded, isFalse);
  });
  test('business error returns a platform error instead of dereferencing null',
      () async {
    apiCode = -352;
    await expectLater(
        site.getPlayQualites(detail: detail), throwsA(isA<CoreError>()));
  });
}

class DelayedDeviceSite extends BiliBiliSite {
  final Completer<Map> gate;
  DelayedDeviceSite(this.gate);
  @override
  Future<Map> getBuvid() => gate.future;
}

class DanmakuSite extends BiliBiliSite {
  @override
  Future<Map<String, String>> getWbiSign(String url) async => {};
  @override
  Future<Map<String, dynamic>> getRoomInfo({required String roomId}) async => {
        'room_info': {
          'room_id': 123,
          'title': '',
          'cover': '',
          'online': 0,
          'live_status': 1,
          'description': ''
        },
        'anchor_info': {
          'base_info': {'uname': 'test', 'face': ''}
        },
      };
}
