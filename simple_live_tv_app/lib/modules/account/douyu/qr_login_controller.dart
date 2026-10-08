import 'dart:async';
import 'package:get/get.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/services/douyu_account_service.dart';

enum DouyuQRStatus { loading, waiting, scanned, expired, failed }

class DouyuQRLoginController extends GetxController {
  DouyuQRLoginController(
      {DouyuLoginClient Function()? createClient,
      Future<void> Function(String)? saveCookie,
      this.pollInterval = const Duration(seconds: 2)})
      : _createClient = createClient ?? (() => DouyuLoginClient()),
        _saveCookie = saveCookie ??
            ((value) => DouyuAccountService.instance.setCookie(value));
  final DouyuLoginClient Function() _createClient;
  final Future<void> Function(String) _saveCookie;
  final Duration pollInterval;
  final qrStatus = DouyuQRStatus.loading.obs;
  final qrcodeUrl = ''.obs;
  final backFocusNode = AppFocusNode();
  final refreshFocusNode = AppFocusNode();
  DouyuLoginClient? _client;
  Timer? _timer;
  DateTime? _expiresAt;
  int _generation = 0;
  int _failures = 0;
  bool _closed = false;

  @override
  void onInit() {
    super.onInit();
    loadQRCode();
  }

  bool _current(int generation) => !_closed && generation == _generation;
  Future<void> loadQRCode() async {
    if (_closed) return;
    final generation = ++_generation;
    _timer?.cancel();
    _client?.close();
    final client = _client = _createClient();
    qrStatus.value = DouyuQRStatus.loading;
    qrcodeUrl.value = '';
    _failures = 0;
    try {
      final challenge = await client.create();
      if (!_current(generation)) return;
      qrcodeUrl.value = challenge.qrContent;
      _expiresAt = challenge.expiresAt;
      qrStatus.value = DouyuQRStatus.waiting;
      _schedule(generation, client);
    } catch (_) {
      if (_current(generation)) _finish(DouyuQRStatus.failed);
    }
  }

  void _finish(DouyuQRStatus state) {
    _timer?.cancel();
    _client?.close();
    qrStatus.value = state;
    refreshFocusNode.requestFocus();
  }

  void _schedule(int generation, DouyuLoginClient client) {
    if (!_current(generation)) return;
    _timer = Timer(pollInterval, () => _poll(generation, client));
  }

  Future<void> _poll(int generation, DouyuLoginClient client) async {
    if (!_current(generation)) return;
    if (_expiresAt != null && DateTime.now().isAfter(_expiresAt!)) {
      _finish(DouyuQRStatus.expired);
      return;
    }
    try {
      final result = await client.poll();
      if (!_current(generation)) return;
      _failures = 0;
      switch (result.state) {
        case DouyuLoginState.confirmed:
          if (result.cookie == null || result.cookie!.isEmpty) {
            _finish(DouyuQRStatus.failed);
            return;
          }
          await _saveCookie(result.cookie!);
          if (_current(generation)) {
            client.close();
            Get.back(result: true);
          }
          return;
        case DouyuLoginState.expired:
          _finish(DouyuQRStatus.expired);
          return;
        case DouyuLoginState.failed:
          _finish(DouyuQRStatus.failed);
          return;
        case DouyuLoginState.scanned:
          qrStatus.value = DouyuQRStatus.scanned;
          break;
        case DouyuLoginState.waiting:
          qrStatus.value = DouyuQRStatus.waiting;
          break;
      }
    } catch (_) {
      if (!_current(generation)) return;
      if (++_failures >= 3) {
        _finish(DouyuQRStatus.failed);
        return;
      }
    }
    // Schedule only after the entire request/callback finishes.
    _schedule(generation, client);
  }

  @override
  void onClose() {
    _closed = true;
    ++_generation;
    _timer?.cancel();
    _client?.close();
    backFocusNode.dispose();
    refreshFocusNode.dispose();
    super.onClose();
  }
}
