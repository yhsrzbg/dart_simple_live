import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/modules/live_room/live_room_controller.dart';

class ProbeSite extends DouyuSite {
  Future<LivePlayUrl> Function(LivePlayQuality)? fetch;
  @override
  Future<LivePlayUrl> getPlayUrls(
          {required LiveRoomDetail detail, required LivePlayQuality quality}) =>
      fetch!(quality);
  int detailChecks = 0;
  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    ++detailChecks;
    return LiveRoomDetail(
        roomId: roomId,
        title: '',
        cover: '',
        userName: '',
        userAvatar: '',
        online: 0,
        status: true,
        url: '');
  }
}

class ProbeRoom extends LiveRoomController {
  ProbeRoom(ProbeSite site)
      : super(
            pSite: Site(
                id: 'douyu', name: '斗鱼', logo: '', index: 0, liveSite: site),
            pRoomId: '6979222');
  final opens = <String>[];
  @override
  Future<void> setPlayer() async {
    opens.add(playUrls[currentLineIndex]);
  }
}

void main() {
  LivePlayUrl url(String name, {int rate = 0}) => DouyuPlayUrl([
        DouyuStream(
            url: 'https://cdn.test/$name.flv?secret=test',
            cdn: 'test',
            requestedRate: 0,
            actualRate: rate,
            actualQuality: rate == 0 ? '原画1080P60' : '蓝光4M')
      ]);
  ProbeRoom room(ProbeSite site) {
    final r = ProbeRoom(site);
    r.detail.value = LiveRoomDetail(
        roomId: '6979222',
        title: '',
        cover: '',
        userName: '',
        userAvatar: '',
        online: 0,
        status: true,
        url: '');
    r.qualites.add(LivePlayQuality(quality: '原画1080P60', data: null));
    r.currentQuality = 0;
    r.liveStatus.value = true;
    return r;
  }

  Future<void> mount(WidgetTester tester) => tester.pumpWidget(GetMaterialApp(
      builder: FlutterSmartDialog.init(), home: const Scaffold()));
  tearDown(() => Get.reset());
  testWidgets('TV shows actual downgrade and forwards playback headers',
      (tester) async {
    await mount(tester);
    final site = ProbeSite()..fetch = ((_) async => url('four', rate: 4));
    final r = room(site);
    await r.getPlayUrl();
    expect(r.currentQualityInfo.value, '蓝光4M');
    expect(r.playHeaders,
        {'User-Agent': 'libmpv', 'Referer': 'https://www.douyu.com/'});
    expect(r.opens, hasLength(1));
    await tester.pump(const Duration(seconds: 4));
    await SmartDialog.dismiss();
    await tester.pumpAndSettle();
    r.focusNode.dispose();
  });
  testWidgets('late acquisition cannot replace the new selected stream',
      (tester) async {
    await mount(tester);
    final old = Completer<LivePlayUrl>();
    var count = 0;
    final site = ProbeSite()
      ..fetch = ((_) => count++ == 0 ? old.future : Future.value(url('new')));
    final r = room(site);
    final first = r.getPlayUrl();
    await r.getPlayUrl();
    old.complete(url('old'));
    await first;
    expect(r.opens, ['https://cdn.test/new.flv?secret=test']);
    expect(r.playUrls.single, contains('/new.flv'));
    r.focusNode.dispose();
  });
  test('absolute and relative signed playback URLs are hidden from player logs',
      () {
    final r = room(ProbeSite());
    expect(r.formatPlayerLog('GET /live/stream.flv?auth=private HTTP/1.1'),
        isNot(contains('private')));
    expect(r.formatPlayerLog('failed https://cdn.test/stream.flv?auth=private'),
        isNot(contains('private')));
    r.focusNode.dispose();
  });
  testWidgets(
      'EOF and errors fetch new URLs and stop after rapid repeated failures',
      (tester) async {
    await mount(tester);
    var fetches = 0;
    final site = ProbeSite()..fetch = ((_) async => url('request${++fetches}'));
    final r = room(site);
    await r.getPlayUrl();
    r.mediaEnd();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(r.opens.last, contains('/request2.flv'));
    for (var i = 0; i < 2; i++) {
      r.mediaError('failed');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
    }
    r.mediaError('failed');
    await tester.pump();
    expect(fetches, 4);
    expect(site.detailChecks, 1);
    expect(r.liveStatus.value, isTrue);
    expect(r.errorMsg.value, '斗鱼播放中断，请刷新或重新登录');
    r.mediaError('failed again');
    await tester.pump();
    expect(fetches, 4);
    expect(site.detailChecks, 1);
    r.focusNode.dispose();
  });
}
