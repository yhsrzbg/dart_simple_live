import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/http_client.dart' as core_http;
import 'package:test/test.dart';

void main() {
  late Dio original;
  late Dio dio;
  late List<String> paths;
  late Map<String, dynamic> responses;
  Map<String, dynamic> room(String id) => {
        'room': {
          'room_id': int.parse(id),
          'room_biz_all': {'hot': 1},
          'owner_name': 'room-$id',
          'show_status': 1,
          'videoLoop': 0,
        }
      };
  setUp(() {
    CoreLog.enableLog = false;
    original = core_http.HttpClient.instance.dio;
    paths = [];
    responses = {};
    dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
        final path = request.uri.path;
        paths.add(path);
        final data = path.startsWith('/swf_api/h5room/')
            ? {'data': {}}
            : responses[path];
        if (data == null) {
          handler.reject(DioException(requestOptions: request));
        } else {
          handler.resolve(Response(requestOptions: request, data: data));
        }
      }));
    core_http.HttpClient.instance.dio = dio;
  });
  tearDown(() {
    core_http.HttpClient.instance.dio = original;
    dio.close();
  });
  test('74751 is a real five-digit room and never requires HTML parsing',
      () async {
    responses['/betard/74751'] = room('74751');
    final detail = await DouyuSite().getRoomDetail(roomId: '74751');
    expect(detail.roomId, '74751');
    expect(detail.status, isTrue);
    expect(paths, ['/betard/74751', '/swf_api/h5room/74751']);
  });
  test('short real room metadata also accepts the old JSON string response',
      () async {
    responses['/betard/74751'] = jsonEncode(room('74751'));
    final detail = await DouyuSite().getRoomDetail(roomId: '74751');
    expect(detail.roomId, '74751');
    expect(paths, isNot(contains('/74751')));
  });
  test('hot-list selection forwards the real room ID for Super Xiaojie',
      () async {
    responses['/japi/weblist/apinc/allpage/6/1'] = {
      'data': {
        'pgcnt': 1,
        'rl': [
          {
            'type': 1,
            'rid': 74751,
            'rn': '我可能玩了假的马里奥',
            'nn': '超级小桀',
            'rs16': '',
            'ol': 1
          }
        ]
      }
    };
    responses['/betard/74751'] = room('74751');
    final site = DouyuSite();
    final list = await site.getRecommendRooms();
    final selected = list.items.single;
    expect(selected.title, '我可能玩了假的马里奥');
    expect(selected.userName, '超级小桀');
    final detail = await site.getRoomDetail(roomId: selected.roomId);
    expect(detail.roomId, '74751');
    expect(paths, isNot(contains('/74751')));
  });
  test('6657 alias falls back after HTML metadata and uses the canonical room',
      () async {
    responses['/betard/6657'] = '<html>not a canonical room</html>';
    responses['/6657'] = '<div data-room-id="6979222"></div>';
    responses['/betard/6979222'] = room('6979222');
    final detail = await DouyuSite().getRoomDetail(roomId: '6657');
    expect(detail.roomId, '6979222');
    expect(paths, [
      '/betard/6657',
      '/6657',
      '/betard/6979222',
      '/swf_api/h5room/6979222'
    ]);
  });
  test('alias fallback depends on the response rather than ID length',
      () async {
    responses['/betard/123456'] = {'error': 1};
    responses['/123456'] = '<div data-room-id="6979222"></div>';
    responses['/betard/6979222'] = room('6979222');
    final detail = await DouyuSite().getRoomDetail(roomId: '123456');
    expect(detail.roomId, '6979222');
  });
  test(
      'invalid canonical metadata reports a room error instead of a type error',
      () async {
    responses['/betard/6657'] = '<html></html>';
    responses['/6657'] = '<div data-room-id="6979222"></div>';
    responses['/betard/6979222'] = {'room': null};
    await expectLater(
        DouyuSite().getRoomDetail(roomId: '6657'), throwsA(isA<CoreError>()));
    expect(paths, isNot(contains('/swf_api/h5room/6979222')));
  });
}
