import 'package:get/get.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/services/local_storage_service.dart';

class DouyuAccountService extends GetxService {
  DouyuAccountService(
      {DouyuSite? site,
      String Function()? readCookie,
      Future<void> Function(String)? writeCookie,
      Future<bool> Function(String)? validateCookie})
      : _site = site,
        _readCookie = readCookie,
        _writeCookie = writeCookie,
        _validateCookie = validateCookie ?? DouyuLoginClient.validateCookie;

  static DouyuAccountService get instance => Get.find<DouyuAccountService>();
  final DouyuSite? _site;
  final String Function()? _readCookie;
  final Future<void> Function(String)? _writeCookie;
  final Future<bool> Function(String) _validateCookie;
  final logined = false.obs;
  final expired = false.obs;
  final name = '未登录'.obs;
  final revision = 0.obs;
  String cookie = '';
  int _mutation = 0;
  Future<void> _writes = Future.value();

  DouyuSite get site => _site ?? Sites.allSites['douyu']!.liveSite as DouyuSite;

  @override
  void onInit() {
    _apply(_readCookie?.call() ??
        LocalStorageService.instance
            .getValue(LocalStorageService.kDouyuCookie, ''));
    checkAccount();
    super.onInit();
  }

  void _apply(String value) {
    cookie = value;
    site.cookie = value;
    logined.value = value.isNotEmpty;
    name.value = value.isEmpty ? '未登录' : '斗鱼用户';
    final nickname =
        RegExp(r'(?:^|;\s*)acf_nickname=([^;]*)').firstMatch(value)?.group(1);
    if (nickname != null && nickname.isNotEmpty) {
      try {
        name.value = Uri.decodeComponent(nickname);
      } catch (_) {}
    }
  }

  Future<void> _persist(String value) {
    // Keep logout/new login ordering even if a storage operation is slow.
    final operation = _writes.catchError((_) {}).then((_) async {
      if (_writeCookie != null) {
        await _writeCookie!(value);
      } else {
        await LocalStorageService.instance
            .setValue(LocalStorageService.kDouyuCookie, value);
      }
    });
    _writes = operation;
    return operation;
  }

  Future<void> setCookie(String value) async {
    final ticket = ++_mutation;
    await _persist(value);
    if (ticket != _mutation) return;
    _apply(value);
    expired.value = false;
    revision.value++;
  }

  Future<void> checkAccount() async {
    if (cookie.isEmpty) return;
    final ticket = _mutation;
    final snapshot = cookie;
    try {
      final valid = await _validateCookie(snapshot);
      if (ticket == _mutation && snapshot == cookie) expired.value = !valid;
      // Website session and playback JWT can expire independently. Retain the
      // full Cookie until the user replaces it or explicitly logs out.
    } catch (_) {
      // A network failure is not evidence of expired credentials.
    }
  }

  Future<void> logout() async {
    ++_mutation;
    _apply('');
    expired.value = false;
    revision.value++;
    await _persist('');
  }
}
