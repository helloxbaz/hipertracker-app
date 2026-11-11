import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android picture-in-picture: the trip keeps showing in a small floating window when the driver
/// leaves the app (home button or back), like Google Maps.
class Pip {
  Pip._();

  static const _channel = MethodChannel('org.traccar.client/pip');

  /// True while the app is shown in the floating window.
  static final active = ValueNotifier<bool>(false);

  static bool _ready = false;

  static void init() {
    if (_ready) return;
    _ready = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') active.value = call.arguments == true;
    });
  }

  /// Go to the floating window when the app is left (only while a trip screen is open).
  static Future<void> enable(bool on) async {
    try {
      await _channel.invokeMethod('enable', on);
    } catch (_) {}
  }

  /// Shrink into the floating window now. False when the phone can't (older Android, turned off).
  static Future<bool> enter() async {
    try {
      return await _channel.invokeMethod<bool>('enter') ?? false;
    } catch (_) {
      return false;
    }
  }
}
