import 'dart:io';

import 'package:flutter/services.dart';

/// Talks to the native Android LocationGuard, which alerts the phone and the server
/// when location is switched off or permission is removed.
class LocationGuardService {
  static const _channel = MethodChannel('org.traccar.client/location_guard');

  static const String on = 'on';
  static const String off = 'off';
  static const String noPermission = 'no_permission';

  /// Tells the native GPS-off watcher whether the worker is checked in and how often to ring.
  static Future<void> setDuty({
    required bool dutyMode,
    required bool onDuty,
    required int alarmInterval,
    required int escalateAfter,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<String>('setDuty', {
        'dutyMode': dutyMode,
        'onDuty': onDuty,
        'alarmInterval': alarmInterval,
        'escalateAfter': escalateAfter,
      });
    } on PlatformException {
      // older native side; ignore
    } on MissingPluginException {
      // ignore
    }
  }

  /// One fresh location fix for check in / out. Throws [LocationFixException] with a readable message.
  static Future<Map<String, dynamic>> getLocation() async {
    if (!Platform.isAndroid) throw const LocationFixException('Check in from the app is supported on Android only.');
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('getLocation');
      if (result == null) throw const LocationFixException('Could not get your location.');
      return result;
    } on PlatformException catch (e) {
      switch (e.code) {
        case 'permission':
          throw const LocationFixException('Allow HiperTracker to use your location (Allow all the time), then try again.');
        case 'gps_off':
          throw const LocationFixException('Your location (GPS) is switched off. Turn it on and try again.');
        default:
          throw LocationFixException(e.message ?? 'Could not get your location. Try again outside or near a window.');
      }
    }
  }

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

class LocationFixException implements Exception {
  final String message;
  const LocationFixException(this.message);

  @override
  String toString() => message;
}
