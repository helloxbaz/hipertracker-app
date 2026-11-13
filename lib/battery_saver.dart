import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'geolocation_service.dart';
import 'preferences.dart';

/// Below 20% and not charging, tracking switches to Wi-Fi / mobile towers only and reports less often,
/// so the phone lasts the day. Back to the normal mode once charging or above 30%.
/// (The ERP can turn this off: HiperTracker Settings > Save Battery When Low.)
class BatterySaver with WidgetsBindingObserver {
  BatterySaver._();

  static final _instance = BatterySaver._();
  static const _channel = MethodChannel('org.traccar.client/battery');
  static Timer? _timer;

  static void start() {
    WidgetsBinding.instance.addObserver(_instance);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => check());
    check();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) check();
  }

  static Future<void> check() async {
    final p = Preferences.instance;
    final allowed = p.getBool(Preferences.lowBatterySaver) ?? true;
    final saving = p.getBool(Preferences.batterySaving) ?? false;
    int level = 100;
    bool charging = true;
    try {
      final r = await _channel.invokeMapMethod<String, dynamic>('level');
      level = (r?['level'] as num?)?.toInt() ?? 100;
      charging = r?['charging'] == true;
    } catch (_) {
      return;
    }
    final want = allowed && !charging && (saving ? level < 30 : level <= 20);
    if (want == saving) return;
    await p.setBool(Preferences.batterySaving, want);
    try {
      await GeolocationService.tracker.setConfig(Preferences.buildConfig());
    } catch (_) {}
  }
}
