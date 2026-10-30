import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

/// Cookie metadata is only a preflight check; the server still authorizes it.
class DouyuSession {
  DouyuSession(String cookie) {
    for (final part in cookie.split(';')) {
      final separator = part.indexOf('=');
      if (separator > 0) {
        fields[part.substring(0, separator).trim()] =
            part.substring(separator + 1).trim();
      }
    }
  }

  final fields = <String, String>{};
  bool get hasCredential => ['acf_auth', 'dy_auth', 'acf_jwt_token']
      .any((name) => fields[name]?.isNotEmpty ?? false);

  int? get playbackExpiry {
    try {
      final parts = (fields['acf_jwt_token'] ?? '').split('.');
      if (parts.length != 3) return null;
      final payload = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
      final expiry = payload is Map ? payload['exp'] : null;
      return expiry is num &&
              expiry.isFinite &&
              expiry > 0 &&
              expiry <= 9007199254740991 &&
              expiry == expiry.truncateToDouble()
          ? expiry.toInt()
          : null;
    } catch (_) {
      return null;
    }
  }

  bool canPlay(int nowSeconds) => (playbackExpiry ?? 0) > nowSeconds;

  String get device {
    for (final name in ['acf_did', 'dy_did']) {
      final value = fields[name] ?? '';
      if (RegExp(r'^[a-zA-Z0-9]{16,64}$').hasMatch(value)) return value;
    }
    return guestDevice;
  }

  static const guestDevice = '10000000000000000000000000001501';

  static int responseTime(Response<dynamic> response, DateTime fallback) {
    try {
      final date = response.headers.value('date');
      if (date != null) {
        return HttpDate.parse(date).millisecondsSinceEpoch ~/ 1000;
      }
    } catch (_) {}
    return fallback.millisecondsSinceEpoch ~/ 1000;
  }
}
