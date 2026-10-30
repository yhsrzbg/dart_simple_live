import 'dart:async';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/services/bilibili_account_service.dart';

enum QRStatus { loading, unscanned, scanned, expired, failed }

class BiliBiliQRLoginController extends GetxController {
  BiliBiliQRLoginController(
      {BiliBiliLoginClient Function()? createClient,
      Future<void> Function(String)? saveCookie,
      void Function()? finish})
      : _createClient = createClient ?? BiliBiliLoginClient.new,
        _saveCookie = saveCookie,
        _finish = finish;
  final BiliBiliLoginClient Function() _createClient;
  final Future<void> Function(String)? _saveCookie;
  final void Function()? _finish;
  BiliBiliLoginClient? _client;
  Timer? timer;
  final qrcodeUrl = ''.obs;
  final qrStatus = QRStatus.loading.obs;
  int _generation = 0;
  bool _closed = false;
  bool _busy = false;
  bool _finished = false;

  @override
  void onInit() {
    super.onInit();
    loadQRCode();
  }

  Future<void> loadQRCode() async {
    final generation = ++_generation;
    timer?.cancel();
    _client?.close();
    _busy = false;
    _finished = false;
    qrStatus.value = QRStatus.loading;
    qrcodeUrl.value = '';
    final client = _client = _createClient();
    try {
      final content = await client.create();
      if (_closed || generation != _generation) return;
      qrcodeUrl.value = content;
      qrStatus.value = QRStatus.unscanned;
      startPoll();
    } catch (_) {
      if (!_closed && generation == _generation) {
        qrStatus.value = QRStatus.failed;
      }
    }
  }

  void startPoll() {
    timer?.cancel();
    timer = Timer.periodic(const Duration(seconds: 3), (_) => pollQRStatus());
  }

  Future<void> pollQRStatus() async {
    if (_closed ||
        _finished ||
        _busy ||
        _client == null ||
        ![QRStatus.unscanned, QRStatus.scanned].contains(qrStatus.value)) {
      return;
    }
    _busy = true;
    final generation = _generation;
    try {
      final result = await _client!.poll();
      if (_closed || generation != _generation) return;
      switch (result.state) {
        case BiliBiliLoginState.confirmed:
          _finished = true;
          timer?.cancel();
          if (result.cookie?.isNotEmpty != true) {
            throw StateError('missing cookie');
          }
          if (_saveCookie != null) {
            await _saveCookie!(result.cookie!);
          } else {
            await BiliBiliAccountService.instance.setCookie(result.cookie!);
            await BiliBiliAccountService.instance.loadUserInfo();
          }
          if (_closed || generation != _generation) return;
          _client?.close();
          if (_finish != null) {
            _finish!();
          } else {
            Get.back();
          }
          break;
        case BiliBiliLoginState.expired:
          timer?.cancel();
          qrStatus.value = QRStatus.expired;
          _client?.close();
          break;
        case BiliBiliLoginState.failed:
          timer?.cancel();
          qrStatus.value = QRStatus.failed;
          _client?.close();
          break;
        case BiliBiliLoginState.scanned:
          qrStatus.value = QRStatus.scanned;
          break;
        case BiliBiliLoginState.waiting:
          qrStatus.value = QRStatus.unscanned;
          break;
      }
    } catch (_) {
      if (!_closed && generation == _generation) {
        timer?.cancel();
        qrStatus.value = QRStatus.failed;
        SmartDialog.showToast('哔哩哔哩登录失败，请重新获取二维码');
      }
    } finally {
      if (generation == _generation) _busy = false;
    }
  }

  @override
  void onClose() {
    _closed = true;
    ++_generation;
    timer?.cancel();
    _client?.close();
    super.onClose();
  }
}
