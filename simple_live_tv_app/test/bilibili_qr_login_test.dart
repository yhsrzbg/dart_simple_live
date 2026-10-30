import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/modules/account/bilibili/qr_login_controller.dart';

class ProbeLogin extends BiliBiliLoginClient {
  Future<BiliBiliLoginResult> Function()? pollResult;
  var polls = 0;
  var closed = false;
  @override
  Future<String> create() async => 'https://passport.bilibili.com/qr';
  @override
  Future<BiliBiliLoginResult> poll() {
    polls++;
    return pollResult!();
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  test('confirmation persists before finishing and cannot submit twice',
      () async {
    final client = ProbeLogin()
      ..pollResult = (() async => BiliBiliLoginResult(
          BiliBiliLoginState.confirmed,
          cookie: 'SESSDATA=complete'));
    final gate = Completer<void>();
    var saved = '';
    var finished = 0;
    final controller = BiliBiliQRLoginController(
        createClient: () => client,
        saveCookie: (value) async {
          saved = value;
          await gate.future;
        },
        finish: () {
          finished++;
        });
    await controller.loadQRCode();
    final confirming = controller.pollQRStatus();
    await Future<void>.delayed(Duration.zero);
    expect(saved, 'SESSDATA=complete');
    expect(finished, 0);
    await controller.pollQRStatus();
    expect(client.polls, 1);
    gate.complete();
    await confirming;
    await controller.pollQRStatus();
    expect(finished, 1);
    expect(client.polls, 1);
    controller.onClose();
  });
  test('closing during a poll prevents late persistence', () async {
    final pending = Completer<BiliBiliLoginResult>();
    final client = ProbeLogin()..pollResult = (() => pending.future);
    var saved = false;
    final controller = BiliBiliQRLoginController(
        createClient: () => client,
        saveCookie: (_) async {
          saved = true;
        },
        finish: () {});
    await controller.loadQRCode();
    final polling = controller.pollQRStatus();
    controller.onClose();
    pending.complete(
        BiliBiliLoginResult(BiliBiliLoginState.confirmed, cookie: 'late'));
    await polling;
    expect(saved, isFalse);
    expect(client.closed, isTrue);
  });
  test('slow polling is single flight and refreshed QR ignores the old result',
      () async {
    final pending = Completer<BiliBiliLoginResult>();
    final first = ProbeLogin()..pollResult = (() => pending.future);
    final second = ProbeLogin()
      ..pollResult =
          (() async => BiliBiliLoginResult(BiliBiliLoginState.scanned));
    var count = 0;
    var saves = 0;
    final controller = BiliBiliQRLoginController(
        createClient: () => count++ == 0 ? first : second,
        saveCookie: (_) async {
          saves++;
        },
        finish: () {});
    await controller.loadQRCode();
    final old = controller.pollQRStatus();
    await controller.pollQRStatus();
    expect(first.polls, 1);
    await controller.loadQRCode();
    pending.complete(
        BiliBiliLoginResult(BiliBiliLoginState.confirmed, cookie: 'old'));
    await old;
    expect(saves, 0);
    await controller.pollQRStatus();
    expect(controller.qrStatus.value, QRStatus.scanned);
    controller.onClose();
  });
}
