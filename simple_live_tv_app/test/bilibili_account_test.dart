import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/services/bilibili_account_service.dart';

void main() {
  test('persisted account is injected before asynchronous validation',
      () async {
    final site = BiliBiliSite();
    final pending = Completer<BiliBiliAccountResult>();
    final service = BiliBiliAccountService(
        site: site,
        readCookie: () => 'SESSDATA=saved; DedeUserID=123',
        writeCookie: (_) async {},
        checkAccount: (_) => pending.future);
    service.onInit();
    expect(site.cookie, service.cookie);
    expect(site.userId, 123);
    pending.complete(BiliBiliAccountResult(BiliBiliAccountState.valid,
        uid: 123, name: '测试'));
    await Future<void>.delayed(Duration.zero);
    expect(service.name.value, '测试');
  });
  for (final state in [
    BiliBiliAccountState.riskControl,
    BiliBiliAccountState.unavailable,
    BiliBiliAccountState.expired
  ]) {
    test('$state preserves stored credentials and marks only confirmed expiry',
        () async {
      final site = BiliBiliSite();
      var writes = 0;
      final service = BiliBiliAccountService(
          site: site,
          readCookie: () => 'saved',
          writeCookie: (_) async {
            writes++;
          },
          checkAccount: (_) async => BiliBiliAccountResult(state));
      service.onInit();
      await Future<void>.delayed(Duration.zero);
      expect(site.cookie, 'saved');
      expect(service.logined.value, isTrue);
      expect(service.expired.value, state == BiliBiliAccountState.expired);
      expect(service.riskControlled.value,
          state == BiliBiliAccountState.riskControl);
      expect(writes, 0);
    });
  }
  test('late validation cannot expire a replacement account', () async {
    final pending = Completer<BiliBiliAccountResult>();
    final site = BiliBiliSite();
    final service = BiliBiliAccountService(
        site: site,
        readCookie: () => 'old',
        writeCookie: (_) async {},
        checkAccount: (_) => pending.future);
    service.onInit();
    await service.setCookie('SESSDATA=new; DedeUserID=456');
    pending.complete(BiliBiliAccountResult(BiliBiliAccountState.expired));
    await Future<void>.delayed(Duration.zero);
    expect(site.cookie, contains('SESSDATA=new'));
    expect(site.userId, 456);
    expect(service.expired.value, isFalse);
  });
  test('logout wins over a slow save and clears the core session', () async {
    final gate = Completer<void>();
    var stored = '';
    final site = BiliBiliSite();
    final service = BiliBiliAccountService(
        site: site,
        readCookie: () => '',
        writeCookie: (value) async {
          if (value.isNotEmpty) await gate.future;
          stored = value;
        });
    service.onInit();
    final saving = service.setCookie('new');
    final logout = service.logout();
    gate.complete();
    await saving;
    await logout;
    expect(site.cookie, isEmpty);
    expect(stored, isEmpty);
    expect(site.userId, 0);
  });
}
