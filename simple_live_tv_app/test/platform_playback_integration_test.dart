import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/modules/live_room/live_room_controller.dart';

class ProbePlatform extends DouyuSite {
  Future<LivePlayUrl> Function()? fetch;
  int details = 0;
  bool isLive = true;
  @override
  Future<LivePlayUrl> getPlayUrls(
          {required LiveRoomDetail detail, required LivePlayQuality quality}) =>
      fetch!();
  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    details++;
    return roomDetail(live: isLive);
  }
}

LiveRoomDetail roomDetail({bool live = true}) => LiveRoomDetail(
    roomId: '123',
    title: '',
    cover: '',
    userName: '',
    userAvatar: '',
    online: 0,
    status: live,
    url: '');

class ProbeRoom extends LiveRoomController {
  ProbeRoom(String platform, ProbePlatform source)
      : super(
            pSite: Site(
                id: platform,
                name: platform,
                logo: '',
                index: 0,
                liveSite: source),
            pRoomId: '123');
  final opens = <String>[];
  @override
  Future<void> setPlayer() async {
    opens.add(playUrls[currentLineIndex]);
  }
}

void main() {
  tearDown(() => Get.reset());
  Future<void> mount(WidgetTester tester) => tester.pumpWidget(GetMaterialApp(
      builder: FlutterSmartDialog.init(), home: const Scaffold()));
  ProbeRoom room(String provider, ProbePlatform site) {
    final result = ProbeRoom(provider, site);
    result.detail.value = roomDetail();
    result.qualites.add(LivePlayQuality(quality: '原画', data: 10000));
    result.currentQuality = 0;
    result.liveStatus.value = true;
    return result;
  }

  LivePlayUrl urls(int count) => LivePlayUrl(urls: [
        'https://a.test/$count',
        'https://b.test/$count'
      ], urlHeaders: [
        {'user-agent': 'pc'},
        {'user-agent': 'mobile'}
      ]);

  for (final provider in ['huya', 'bilibili']) {
    testWidgets(
        '$provider verifies offline state only after fresh acquisition is exhausted',
        (tester) async {
      await mount(tester);
      var calls = 0;
      final site = ProbePlatform()
        ..isLive = false
        ..fetch = (() async {
          if (++calls == 1) return urls(1);
          throw StateError('no fresh routes');
        });
      final r = room(provider, site);
      await r.getPlayUrl();
      r.mediaEnd();
      await tester.pump();
      expect(r.liveStatus.value, isTrue);
      expect(site.details, 0);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(calls, 4);
      expect(site.details, 1);
      expect(r.liveStatus.value, isFalse);
      r.focusNode.dispose();
    });
    testWidgets(
        '$provider EOF and errors refresh URLs, rotate routes and exhaust a bounded budget',
        (tester) async {
      await mount(tester);
      var calls = 0;
      final site = ProbePlatform()..fetch = (() async => urls(++calls));
      final r = room(provider, site);
      await r.getPlayUrl();
      r.mediaEnd();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(r.opens.last, 'https://a.test/2');
      r.mediaError('expired');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(r.opens.last, 'https://b.test/3');
      expect(r.playHeaders!['user-agent'], 'mobile');
      r.mediaError('again');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      r.mediaError('again');
      await tester.pump();
      expect(calls, 4);
      expect(site.details, 1);
      expect(r.liveStatus.value, isTrue);
      expect(r.errorMsg.value, contains('播放中断'));
      r.mediaError('repeat');
      await tester.pump();
      expect(calls, 4);
      r.focusNode.dispose();
    });
    testWidgets('$provider late recovery cannot replace a manual selection',
        (tester) async {
      await mount(tester);
      final pending = Completer<LivePlayUrl>();
      var calls = 0;
      final site = ProbePlatform()
        ..fetch =
            (() => ++calls == 2 ? pending.future : Future.value(urls(calls)));
      final r = room(provider, site);
      await r.getPlayUrl();
      r.mediaError('expired');
      await tester.pump();
      await r.getPlayUrl(line: 1);
      pending.complete(urls(2));
      await tester.pump();
      expect(r.opens.last, 'https://b.test/3');
      expect(r.opens, isNot(contains('https://a.test/2')));
      r.focusNode.dispose();
    });
  }
  testWidgets('Bilibili displays actual qn while preserving the requested tier',
      (tester) async {
    await mount(tester);
    final site = ProbePlatform()
      ..fetch = (() async => BiliBiliPlayUrl([
            BiliBiliStream(
                url: 'https://a.test/live',
                requestedQn: 10000,
                actualQn: 400,
                actualQuality: '蓝光'),
          ]));
    final r = room('bilibili', site);
    await r.getPlayUrl();
    expect(r.currentQualityInfo.value, '蓝光');
    expect(r.qualites[r.currentQuality].data, 10000);
    await tester.pump(const Duration(seconds: 4));
    await SmartDialog.dismiss();
    await tester.pumpAndSettle();
    r.focusNode.dispose();
  });
}
