import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/services/douyu_account_service.dart';

void main() {
  test('startup injects the persisted full Cookie before validation', () async {
    final site = DouyuSite();
    final pending = Completer<bool>();
    final service = DouyuAccountService(
        site: site,
        readCookie: () => 'acf_auth=test; acf_nickname=%E6%B5%8B%E8%AF%95',
        writeCookie: (_) async {},
        validateCookie: (_) => pending.future);
    service.onInit();
    expect(site.cookie, service.cookie);
    expect(service.name.value, '测试');
    expect(service.logined.value, isTrue);
    pending.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(service.expired.value, isFalse);
  });
  test('new login persists and updates core, logout clears both', () async {
    final site = DouyuSite();
    var stored = '';
    final service = DouyuAccountService(
        site: site,
        readCookie: () => '',
        writeCookie: (s) async {
          stored = s;
        });
    service.onInit();
    await service.setCookie('acf_auth=test; acf_jwt_token=jwt; acf_uid=123');
    expect(site.cookie, stored);
    expect(service.revision.value, 1);
    await service.logout();
    expect(site.cookie, '');
    expect(stored, '');
    expect(service.logined.value, isFalse);
    expect(service.revision.value, 2);
  });
  test('network failure retains login and playback credentials', () async {
    final site = DouyuSite();
    final service = DouyuAccountService(
        site: site,
        readCookie: () => 'saved',
        writeCookie: (_) async {},
        validateCookie: (_) async => throw StateError('network'));
    service.onInit();
    await Future<void>.delayed(Duration.zero);
    expect(service.cookie, 'saved');
    expect(service.expired.value, isFalse);
  });
  test('expired website session retains Cookie for independent playback JWT',
      () async {
    final site = DouyuSite();
    final service = DouyuAccountService(
        site: site,
        readCookie: () => 'saved',
        writeCookie: (_) async {},
        validateCookie: (_) async => false);
    service.onInit();
    await Future<void>.delayed(Duration.zero);
    expect(service.expired.value, isTrue);
    expect(site.cookie, 'saved');
  });
  test('late validation cannot mark a new account expired', () async {
    final pending = Completer<bool>();
    final service = DouyuAccountService(
        site: DouyuSite(),
        readCookie: () => 'old',
        writeCookie: (_) async {},
        validateCookie: (_) => pending.future);
    service.onInit();
    await service.setCookie('new');
    pending.complete(false);
    await Future<void>.delayed(Duration.zero);
    expect(service.cookie, 'new');
    expect(service.expired.value, isFalse);
  });
  test('logout wins over slow save without restoring old credentials',
      () async {
    final gate = Completer<void>();
    var stored = '';
    final site = DouyuSite();
    final service = DouyuAccountService(
        site: site,
        readCookie: () => '',
        writeCookie: (s) async {
          if (s.isNotEmpty) await gate.future;
          stored = s;
        });
    service.onInit();
    final login = service.setCookie('new');
    final logout = service.logout();
    gate.complete();
    await login;
    await logout;
    expect(stored, '');
    expect(site.cookie, '');
    expect(service.logined.value, isFalse);
  });
}
