import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/modules/account/douyu/qr_login_controller.dart';
import 'package:simple_live_tv_app/modules/account/douyu/qr_login_page.dart';

class FakeLogin extends DouyuLoginClient {
  Future<DouyuLoginChallenge>? creation;
  Future<DouyuLoginResult>? polling;
  int polls = 0;
  bool closed = false;
  @override
  Future<DouyuLoginChallenge> create() =>
      creation ??
      Future.value(DouyuLoginChallenge('https://passport.douyu.com/scan/test',
          DateTime.now().add(const Duration(minutes: 2))));
  @override
  Future<DouyuLoginResult> poll() {
    ++polls;
    return polling ?? Future.value(DouyuLoginResult(DouyuLoginState.waiting));
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  tearDown(() => Get.reset());
  testWidgets('confirmed login saves credentials before returning from QR page',
      (tester) async {
    final gate = Completer<void>();
    var saved = '';
    final fake = FakeLogin()
      ..polling = Future.value(DouyuLoginResult(DouyuLoginState.confirmed,
          cookie: 'complete-test-cookie'));
    final controller = DouyuQRLoginController(
        createClient: () => fake,
        saveCookie: (value) async {
          saved = value;
          await gate.future;
        });
    await tester.pumpWidget(ScreenUtilInit(
        designSize: const Size(1920, 1080),
        builder: (_, __) => GetMaterialApp(
            home: Scaffold(
                body: TextButton(
                    onPressed: () => Get.to(() => const DouyuQRLoginPage(),
                            binding: BindingsBuilder(() {
                          Get.put<DouyuQRLoginController>(controller);
                        })),
                    child: const Text('打开登录'))))));
    await tester.tap(find.text('打开登录'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(saved, 'complete-test-cookie');
    expect(find.byType(DouyuQRLoginPage), findsOneWidget);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(DouyuQRLoginPage), findsNothing);
    expect(fake.closed, isTrue);
  });
  testWidgets('polling never overlaps a slow upstream request', (tester) async {
    final pending = Completer<DouyuLoginResult>();
    final fake = FakeLogin()..polling = pending.future;
    final controller = DouyuQRLoginController(
        createClient: () => fake,
        saveCookie: (_) async {},
        pollInterval: const Duration(seconds: 1));
    await controller.loadQRCode();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 10));
    expect(fake.polls, 1);
    controller.onClose();
    pending.complete(DouyuLoginResult(DouyuLoginState.waiting));
    await tester.pump();
  });
  testWidgets('closing during confirmation never saves late credentials',
      (tester) async {
    final pending = Completer<DouyuLoginResult>();
    final fake = FakeLogin()..polling = pending.future;
    var saves = 0;
    final controller = DouyuQRLoginController(
        createClient: () => fake,
        saveCookie: (_) async {
          ++saves;
        });
    await controller.loadQRCode();
    await tester.pump(const Duration(seconds: 2));
    controller.onClose();
    pending.complete(
        DouyuLoginResult(DouyuLoginState.confirmed, cookie: 'test-only'));
    await tester.pump();
    expect(saves, 0);
    expect(fake.closed, isTrue);
  });
  testWidgets('refresh ignores the previous QR creation response',
      (tester) async {
    final pending = Completer<DouyuLoginChallenge>();
    final old = FakeLogin()..creation = pending.future;
    final fresh = FakeLogin();
    var creations = 0;
    final controller = DouyuQRLoginController(
        createClient: () => creations++ == 0 ? old : fresh,
        saveCookie: (_) async {});
    final first = controller.loadQRCode();
    await controller.loadQRCode();
    pending
        .complete(DouyuLoginChallenge('https://passport.douyu.com/old', null));
    await first;
    expect(controller.qrcodeUrl.value, 'https://passport.douyu.com/scan/test');
    expect(old.closed, isTrue);
    controller.onClose();
  });
  testWidgets('expired QR stops polling and shows a refresh action',
      (tester) async {
    final fake = FakeLogin()
      ..polling = Future.value(DouyuLoginResult(DouyuLoginState.expired));
    final controller = DouyuQRLoginController(
        createClient: () => fake, saveCookie: (_) async {});
    Get.put(controller);
    await tester.pumpWidget(ScreenUtilInit(
        designSize: const Size(1920, 1080),
        builder: (_, __) => const GetMaterialApp(home: DouyuQRLoginPage())));
    await tester.pump();
    expect(find.byType(QrImageView), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(controller.qrStatus.value, DouyuQRStatus.expired);
    expect(find.text('二维码已失效，请刷新'), findsOneWidget);
    expect(find.text('刷新二维码'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);
    await tester.pump(const Duration(seconds: 10));
    expect(fake.polls, 1);
    await tester.pumpWidget(const SizedBox());
  });
}
