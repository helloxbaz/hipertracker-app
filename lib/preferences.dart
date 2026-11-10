import 'dart:io';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_android/shared_preferences_android.dart';
import 'package:traccar_client_sdk/traccar_client_sdk.dart';

class Preferences {
  static Future<void>? _initFuture;
  static late SharedPreferencesWithCache instance;

  static const String id = 'id';
  static const String url = 'url';
  static const String accuracy = 'accuracy';
  static const String distance = 'distance';
  static const String interval = 'interval';
  static const String angle = 'angle';
  static const String heartbeat = 'heartbeat';
  static const String buffer = 'buffer';
  static const String wakelock = 'wakelock';
  static const String stopDetection = 'stop_detection';
  static const String preferPlatformProviders = 'prefer_platform_providers';
  static const String password = 'password';

  // Hipersign ERP (check in / check out); the ERP password itself is kept in secure storage
  static const String erpUrl = 'erp_url';
  static const String erpUser = 'erp_user';
  static const String erpSid = 'erp_sid';
  static const String erpEmployee = 'erp_employee';
  static const String erpEmployeeName = 'erp_employee_name';
  static const String onDuty = 'on_duty';
  static const String dutySince = 'duty_since';
  static const String dutyMode = 'duty_mode';
  static const String alarmInterval = 'alarm_interval';
  static const String escalateAfter = 'escalate_after';
  static const String requireLocation = 'require_location';
  // set when the phone is used without an ERP account (server address + ID only, like Traccar)
  static const String trackingOnly = 'tracking_only';
  // trip screen: speak directions (on unless turned off)
  static const String tripVoice = 'trip_voice';
  // trip screen: the chosen voice and how fast it speaks
  static const String tripVoiceName = 'trip_voice_name';
  static const String tripVoiceLocale = 'trip_voice_locale';
  static const String tripVoiceRate = 'trip_voice_rate';

  static Future<void> init() async {
    _initFuture ??= _createInstance();
    await _initFuture;
  }

  static Future<void> _createInstance() async {
    instance = await SharedPreferencesWithCache.create(
      sharedPreferencesOptions: Platform.isAndroid
          ? SharedPreferencesAsyncAndroidOptions(backend: SharedPreferencesAndroidBackendLibrary.SharedPreferences)
          : SharedPreferencesOptions(),
      cacheOptions: SharedPreferencesWithCacheOptions(
        allowList: {
          id, url, accuracy, distance, interval, angle, heartbeat, buffer, wakelock, stopDetection, preferPlatformProviders, password,
          erpUrl, erpUser, erpSid, erpEmployee, erpEmployeeName, onDuty, dutySince, dutyMode, alarmInterval, escalateAfter,
          requireLocation, trackingOnly, tripVoice, tripVoiceName, tripVoiceLocale, tripVoiceRate,
        },
      ),
    );
    if (Platform.isAndroid) {
      for (final key in {interval, distance, angle, heartbeat}) {
        if (instance.get(key) is String) {
          await instance.setInt(key, int.tryParse(instance.getString(key) ?? '') ?? 0);
        }
      }
    }
    // a short server address (just the ERP site) is stored as the full location address
    final storedUrl = instance.getString(url);
    if (storedUrl != null && storedUrl.isNotEmpty && normalizeServerUrl(storedUrl) != storedUrl) {
      await instance.setString(url, normalizeServerUrl(storedUrl));
    }
    if (instance.getString(id) == null) {
      await instance.setString(id, (Random().nextInt(90000000) + 10000000).toString());
      // locations go straight to Hipersign ERP, which knows the phone by its ID (like Traccar)
      await instance.setString(url, normalizeServerUrl('https://nexus365.hipersignerp.cloud'));
      await instance.setString(accuracy, 'medium');
      await instance.setInt(interval, 300);
      await instance.setInt(distance, 75);
      await instance.setBool(buffer, true);
      await instance.setBool(stopDetection, true);
    }
  }

  static const String erpLocationPath = '/api/method/hipertracker_position';

  /// Lets people type just the ERP site, e.g. `nexus365.hipersignerp.cloud`: the phone then reports to
  /// that ERP's HiperTracker location address. Full addresses and Traccar-style `host:5055` stay as they are.
  static String normalizeServerUrl(String value) {
    var v = value.trim();
    if (v.isEmpty) return v;
    if (!v.contains('://')) v = 'https://$v';
    final uri = Uri.tryParse(v);
    if (uri == null || uri.host.isEmpty) return v;
    if ((uri.path.isEmpty || uri.path == '/') && !uri.hasPort) {
      return uri.replace(path: erpLocationPath).toString();
    }
    return v;
  }

  /// The server address as people typed it: the ERP site without the location path or device key.
  static String displayServerUrl(String? value) {
    final v = value ?? '';
    final uri = Uri.tryParse(v);
    if (uri != null && uri.host.isNotEmpty && uri.path == erpLocationPath) return uri.origin;
    return v.split('?').first;
  }

  static Config buildConfig() {
    return Config(
      serverUrl: instance.getString(url) ?? '',
      deviceId: instance.getString(id) ?? '',
      location: LocationConfig(
        accuracy: switch (instance.getString(accuracy)) {
          'highest' => Accuracy.highest,
          'high' => Accuracy.high,
          'low' => Accuracy.low,
          _ => Accuracy.medium,
        },
        distanceMeters: instance.getInt(distance) ?? 75,
        intervalSeconds: instance.getInt(interval) ?? 300,
        angleDegrees: instance.getInt(angle) ?? 0,
        heartbeatIntervalSeconds: instance.getInt(heartbeat) ?? 0,
        stopDetection: instance.getBool(stopDetection) ?? true,
      ),
      wakeLock: instance.getBool(wakelock) ?? false,
      buffer: instance.getBool(buffer) ?? true,
      preferPlatformProviders: instance.getBool(preferPlatformProviders) ?? false,
    );
  }
}
