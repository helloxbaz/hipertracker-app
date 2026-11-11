import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The navigation card in the notification bar / lock screen while driving a trip (like Google Maps):
/// next turn, distance, arrival time, progress and "Exit navigation".
class NavNotify {
  NavNotify._();

  static const _channel = MethodChannel('org.traccar.client/nav');
  static VoidCallback? onExit; // "Exit navigation" tapped
  static final Map<int, Uint8List> _icons = {};
  static String _last = '';

  static void init() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'exit') onExit?.call();
    });
  }

  /// The turn arrow as a picture for the notification.
  static Future<Uint8List?> _icon(IconData icon) async {
    final hit = _icons[icon.codePoint];
    if (hit != null) return hit;
    const s = 128.0;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(fontSize: s, fontFamily: icon.fontFamily, package: icon.fontPackage, color: const Color(0xFF4285F4)),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, Offset((s - tp.width) / 2, (s - tp.height) / 2));
    final img = await rec.endRecording().toImage(s.toInt(), s.toInt());
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) return null;
    return _icons[icon.codePoint] = png.buffer.asUint8List();
  }

  /// Show or update the card (skipped when nothing changed).
  static Future<void> show({
    required IconData icon,
    required String title,
    required String text,
    required double progress, // 0..1
  }) async {
    final p = (progress.clamp(0.0, 1.0) * 1000).round();
    final key = '${icon.codePoint}|$title|$text|${p ~/ 10}';
    if (key == _last) return;
    _last = key;
    try {
      await _channel.invokeMethod('show', {
        'title': title,
        'text': text,
        'icon': await _icon(icon),
        'progress': p,
        'color': 0xFF1A73E8,
      });
    } catch (_) {}
  }

  static Future<void> hide() async {
    _last = '';
    try {
      await _channel.invokeMethod('hide');
    } catch (_) {}
  }
}
