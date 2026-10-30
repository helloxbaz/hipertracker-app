import 'dart:io';

import 'package:flutter/services.dart';

/// Talks to the native Android LocationGuard, which alerts the phone and the server
/// when location is switched off or permission is removed.
class LocationGuardService {
  static const _channel = MethodChannel('org.traccar.client/location_guard');

  static const String on = 'on';
  static const String off = 'off';
  static const String noPermission = 'no_permission';

  /// Re-checks location state (sending any alert that is due) and returns it.
  static Future<String> check() async {
    if (!Platform.isAndroid) return on;
    try {
      return await _channel.invokeMethod<String>('check') ?? on;
    } on PlatformException {
      return on;
    } on MissingPluginException {
      return on;
    }
  }
}
