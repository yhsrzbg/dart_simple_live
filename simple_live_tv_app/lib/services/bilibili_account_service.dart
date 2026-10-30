import 'package:get/get.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/services/local_storage_service.dart';

class BiliBiliAccountService extends GetxService {
  BiliBiliAccountService(
      {BiliBiliSite? site,
      String Function()? readCookie,
      Future<void> Function(String)? writeCookie,
      Future<BiliBiliAccountResult> Function(String)? checkAccount})
      : _site = site,
        _readCookie = readCookie,
        _writeCookie = writeCookie,
        _checkAccount = checkAccount ?? BiliBiliLoginClient.checkAccount;
  static BiliBiliAccountService get instance =>
      Get.find<BiliBiliAccountService>();
  final BiliBiliSite? _site;
  final String Function()? _readCookie;
  final Future<void> Function(String)? _writeCookie;
  final Future<BiliBiliAccountResult> Function(String) _checkAccount;
  final logined = false.obs;
  final expired = false.obs;
  final riskControlled = false.obs;
  final revision = 0.obs;
  final name = '未登录'.obs;
  String cookie = '';
  int uid = 0;
  int _mutation = 0;
  Future<void> _writes = Future.value();
  BiliBiliSite get site =>
      _site ?? Sites.allSites[Constant.kBiliBili]!.liveSite as BiliBiliSite;

  @override
  void onInit() {
    _apply(_readCookie?.call() ??
        LocalStorageService.instance
            .getValue(LocalStorageService.kBilibiliCookie, ''));
    loadUserInfo();
    super.onInit();
  }

  void _apply(String value) {
    cookie = value;
    uid =
        int.tryParse(BiliBiliSite.cookieFields(value)['DedeUserID'] ?? '') ?? 0;
    logined.value = value.isNotEmpty;
    name.value = value.isEmpty ? '未登录' : '哔哩哔哩用户';
    setSite();
  }

  void setSite() {
    site.cookie = cookie;
    site.userId = uid;
  }

  Future<void> loadUserInfo() async {
    if (cookie.isEmpty) return;
    final ticket = _mutation;
    final snapshot = cookie;
    try {
      final result = await _checkAccount(snapshot);
      if (ticket != _mutation || snapshot != cookie) return;
      switch (result.state) {
        case BiliBiliAccountState.valid:
          expired.value = false;
          riskControlled.value = false;
          uid = result.uid;
          name.value = result.name.isEmpty ? '哔哩哔哩用户' : result.name;
          setSite();
          break;
        case BiliBiliAccountState.expired:
          expired.value = true;
          riskControlled.value = false;
          break;
        case BiliBiliAccountState.riskControl:
          riskControlled.value = true;
          break;
        case BiliBiliAccountState.unavailable:
          break;
      }
    } catch (_) {
      // A failed check does not erase credentials or establish expiry.
    }
  }

  Future<void> _persist(String value) {
    final operation = _writes.catchError((_) {}).then((_) async {
      if (_writeCookie != null) {
        await _writeCookie!(value);
      } else {
        await LocalStorageService.instance
            .setValue(LocalStorageService.kBilibiliCookie, value);
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
    riskControlled.value = false;
    revision.value++;
  }

  Future<void> logout() async {
    ++_mutation;
    _apply('');
    expired.value = false;
    riskControlled.value = false;
    revision.value++;
    await _persist('');
  }
}
