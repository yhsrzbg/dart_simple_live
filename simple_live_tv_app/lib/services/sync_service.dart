import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/event_bus.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/app/utils.dart';
import 'package:simple_live_tv_app/models/db/follow_user.dart';
import 'package:simple_live_tv_app/models/db/history.dart';
import 'package:simple_live_tv_app/services/bilibili_account_service.dart';
import 'package:simple_live_tv_app/services/db_service.dart';
import 'package:udp/udp.dart';
import 'package:uuid/uuid.dart';

class SyncService extends GetxService {
  static SyncService get instance => Get.find<SyncService>();

  UDP? udp;
  static const int udpPort = 23235;
  static const int httpPort = 23234;
  DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
  NetworkInfo networkInfo = NetworkInfo();
  HttpServer? server;

  var ipAddress = ''.obs;
  var httpRunning = false.obs;
  var httpErrorMsg = ''.obs;

  var deviceId = '';

  @override
  void onInit() {
    Log.d('SyncService init');
    deviceId = (const Uuid().v4()).split('-').first;
    listenUDP();
    initServer();
    super.onInit();
  }

  void listenUDP() async {
    udp = await UDP.bind(Endpoint.any(port: const Port(udpPort)));
    udp!.asStream().listen((datagram) {
      var str = String.fromCharCodes(datagram!.data);
      Log.i('Received: $str from ${datagram.address}:${datagram.port}');
      if (str.startsWith('{') && str.endsWith('}')) {
        var data = json.decode(str);
        if (data['type'] == 'hello') {
          if (httpRunning.value) {
            sendInfo();
          }
          return;
        }
      } else if (str == 'Who is SimpleLive?') {
        if (httpRunning.value) {
          sendInfo();
        }
      }
    });
  }

  void sendInfo() async {
    var name = await getDeviceName();
    var data = {
      'id': deviceId,
      'type': 'tv',
      'name': name,
    };

    await udp!.send(
      json.encode(data).codeUnits,
      Endpoint.broadcast(
        port: const Port(udpPort),
      ),
    );
    Log.i('send udp info: $data');
  }

  Future<String> getLocalIP() async {
    var ip = await networkInfo.getWifiIP();
    if (ip == null || ip.isEmpty) {
      var interfaces = await NetworkInterface.list();
      var ipList = <String>[];
      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
          if (addr.type.name == 'IPv4' &&
              !addr.address.startsWith('127') &&
              !addr.isMulticast &&
              !addr.isLoopback) {
            ipList.add(addr.address);
            break;
          }
        }
      }
      ip = ipList.join(';');
    }
    return ip;
  }

  Future<String> getDeviceName() async {
    var name = 'SimpleLive-TV';
    if (Platform.isAndroid) {
      var info = await deviceInfo.androidInfo;
      name = info.model;
    } else if (Platform.isIOS) {
      var info = await deviceInfo.iosInfo;
      name = info.name;
    } else if (Platform.isMacOS) {
      var info = await deviceInfo.macOsInfo;
      name = info.computerName;
    } else if (Platform.isLinux) {
      var info = await deviceInfo.linuxInfo;
      name = info.name;
    } else if (Platform.isWindows) {
      var info = await deviceInfo.windowsInfo;
      name = info.userName;
    }
    return name;
  }

  void initServer() async {
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, httpPort);
      server!.autoCompress = true;
      server!.listen(_handleHttpRequest);

      httpRunning.value = true;
      var ip = await getLocalIP();
      ipAddress.value = ip;

      Log.d('Serving at http://$ip:${server!.port}');
    } catch (e) {
      httpErrorMsg.value = e.toString();
      Log.logPrint(e);
    }
  }

  Future<void> _handleHttpRequest(HttpRequest request) async {
    final method = request.method.toUpperCase();
    final path = request.uri.path;

    Map<String, dynamic> data;
    int statusCode = HttpStatus.ok;

    try {
      if (method == 'GET' && path == '/') {
        data = _helloRequest();
      } else if (method == 'GET' && path == '/info') {
        data = await _infoRequest();
      } else if (method == 'POST' && path == '/sync/follow') {
        final body = await utf8.decoder.bind(request).join();
        data = await _syncFollowUserRequest(request.uri, body);
      } else if (method == 'POST' && path == '/sync/history') {
        final body = await utf8.decoder.bind(request).join();
        data = await _syncHistoryRequest(request.uri, body);
      } else if (method == 'POST' && path == '/sync/blocked_word') {
        final body = await utf8.decoder.bind(request).join();
        data = await _syncBlockedWordRequest(request.uri, body);
      } else if (method == 'POST' && path == '/sync/account/bilibili') {
        final body = await utf8.decoder.bind(request).join();
        data = await _syncBiliAccountRequest(body);
      } else {
        statusCode = HttpStatus.notFound;
        data = {
          'status': false,
          'message': 'Not found',
        };
      }
    } catch (e) {
      statusCode = HttpStatus.internalServerError;
      data = {
        'status': false,
        'message': e.toString(),
      };
    }

    await _writeJsonResponse(request.response, data, statusCode: statusCode);
  }

  Map<String, dynamic> _helloRequest() {
    return {
      'status': true,
      'message': 'http server is running...',
      'version':
          'SimpeLive ${Platform.operatingSystem} v${Utils.packageInfo.version}',
    };
  }

  Future<Map<String, dynamic>> _infoRequest() async {
    var name = await getDeviceName();
    return {
      'id': deviceId,
      'type': 'tv',
      'name': name,
      'version': Utils.packageInfo.version,
      'address': ipAddress.value,
      'port': httpPort,
    };
  }

  Future<Map<String, dynamic>> _syncFollowUserRequest(
    Uri uri,
    String body,
  ) async {
    try {
      var overlay = int.parse(uri.queryParameters['overlay'] ?? '0');

      Log.d('_syncFollowUserRequest: $body');
      var jsonBody = json.decode(body);
      if (overlay == 1) {
        await DBService.instance.followBox.clear();
      }
      for (var item in jsonBody) {
        var user = FollowUser.fromJson(item);
        await DBService.instance.followBox.put(user.id, user);
      }

      SmartDialog.showToast('Sync follow list complete');
      EventBus.instance.emit(Constant.kUpdateFollow, 0);
      return {
        'status': true,
        'message': 'success',
      };
    } catch (e) {
      return {
        'status': false,
        'message': e.toString(),
      };
    }
  }

  Future<Map<String, dynamic>> _syncHistoryRequest(Uri uri, String body) async {
    try {
      var overlay = int.parse(uri.queryParameters['overlay'] ?? '0');
      Log.d('_syncHistoryRequest: $body');
      var jsonBody = json.decode(body);
      if (overlay == 1) {
        await DBService.instance.historyBox.clear();
      }
      for (var item in jsonBody) {
        var history = History.fromJson(item);
        if (DBService.instance.historyBox.containsKey(history.id)) {
          var old = DBService.instance.historyBox.get(history.id);
          if (old!.updateTime.isAfter(history.updateTime)) {
            continue;
          }
        }
        await DBService.instance.addOrUpdateHistory(history);
      }

      SmartDialog.showToast('Sync history complete');
      EventBus.instance.emit(Constant.kUpdateHistory, 0);
      return {
        'status': true,
        'message': 'success',
      };
    } catch (e) {
      return {
        'status': false,
        'message': e.toString(),
      };
    }
  }

  Future<Map<String, dynamic>> _syncBlockedWordRequest(
    Uri uri,
    String body,
  ) async {
    try {
      var overlay = int.parse(uri.queryParameters['overlay'] ?? '0');
      Log.d('_syncBlockedWordRequest: $body');
      var jsonBody = json.decode(body);
      if (overlay == 1) {
        AppSettingsController.instance.clearShieldList();
      }
      for (var keyword in jsonBody) {
        AppSettingsController.instance.addShieldList(keyword.trim());
      }
      SmartDialog.showToast('Sync blocked words complete');
      return {
        'status': true,
        'message': 'success',
      };
    } catch (e) {
      return {
        'status': false,
        'message': e.toString(),
      };
    }
  }

  Future<Map<String, dynamic>> _syncBiliAccountRequest(String body) async {
    try {
      Log.d('_syncBiliAccountRequest: $body');
      var jsonBody = json.decode(body);
      var cookie = jsonBody['cookie'];
      BiliBiliAccountService.instance.setCookie(cookie);
      BiliBiliAccountService.instance.loadUserInfo();
      SmartDialog.showToast('Sync bilibili account complete');
      return {
        'status': true,
        'message': 'success',
      };
    } catch (e) {
      return {
        'status': false,
        'message': e.toString(),
      };
    }
  }

  Future<void> _writeJsonResponse(
    HttpResponse response,
    Map<String, dynamic> data, {
    int statusCode = HttpStatus.ok,
  }) async {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    response.write(json.encode(data));
    await response.close();
  }

  @override
  void onClose() {
    Log.d('SyncService close');
    udp?.close();
    server?.close(force: true);
    super.onClose();
  }
}
