import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;

/// Map pictures for the Google map on the trip screen (stops, petrol pumps, route labels, the arrow),
/// drawn once with a canvas and kept.
class NavIcons {
  NavIcons._();

  static final Map<String, gm.BitmapDescriptor> _cache = {};
  static final Set<String> _making = {};

  /// The picture for [key] if it's ready; otherwise starts drawing it and calls [ready] when done.
  static gm.BitmapDescriptor? get(String key, double dpr, Future<ui.Image> Function(double dpr) draw,
      VoidCallback ready) {
    final hit = _cache[key];
    if (hit != null) return hit;
    if (_making.add(key)) {
      draw(dpr).then((img) async {
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        if (png != null) {
          _cache[key] = gm.BitmapDescriptor.bytes(png.buffer.asUint8List(), imagePixelRatio: dpr);
        }
        _making.remove(key);
        ready();
      });
    }
    return null;
  }

  static Future<ui.Image> _paint(double w, double h, double dpr, void Function(Canvas c) paint) {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.scale(dpr);
    paint(c);
    return rec.endRecording().toImage((w * dpr).ceil(), (h * dpr).ceil());
  }

  static TextPainter _text(String s, double size, Color color, {FontWeight weight = FontWeight.w600, double? max}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(fontSize: size, color: color, fontWeight: weight)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    );
    tp.layout(maxWidth: max ?? double.infinity);
    return tp;
  }

  /// A numbered stop badge; the next stop also gets its name under it.
  static Future<ui.Image> stop(double dpr, {required int number, required Color color, String? name}) {
    const d = 34.0;
    final label = name == null ? null : _text(name, 13, Colors.white, max: 150);
    final w = math.max(d + 8, (label?.width ?? 0) + 20);
    final h = d + 8 + (label == null ? 0 : label.height + 12);
    return _paint(w, h, dpr, (c) {
      final cx = w / 2;
      const cy = d / 2 + 4;
      c.drawCircle(Offset(cx, cy + 1.5), d / 2 + 1, Paint()..color = const Color(0x55000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2));
      c.drawCircle(Offset(cx, cy), d / 2, Paint()..color = Colors.white);
      c.drawCircle(Offset(cx, cy), d / 2 - 3, Paint()..color = color);
      final n = _text('$number', 15, Colors.white, weight: FontWeight.w800);
      n.paint(c, Offset(cx - n.width / 2, cy - n.height / 2));
      if (label != null) {
        final r = RRect.fromRectAndRadius(
            Rect.fromLTWH(cx - label.width / 2 - 8, d + 10, label.width + 16, label.height + 8), const Radius.circular(10));
        c.drawRRect(r, Paint()..color = const Color(0xFF1F2A44));
        label.paint(c, Offset(cx - label.width / 2, d + 14));
      }
    });
  }

  /// A petrol pump pin (filled when it's where we are going).
  static Future<ui.Image> pump(double dpr, {bool going = false}) {
    const s = 34.0;
    const orange = Color(0xFFE37400);
    return _paint(s, s, dpr, (c) {
      const o = Offset(s / 2, s / 2);
      c.drawCircle(o, s / 2 - 1, Paint()..color = going ? orange : Colors.white);
      c.drawCircle(o, s / 2 - 2, Paint()
        ..color = orange
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2);
      final icon = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(Icons.local_gas_station.codePoint),
          style: TextStyle(fontSize: 20, fontFamily: Icons.local_gas_station.fontFamily, color: going ? Colors.white : orange),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      icon.paint(c, Offset(o.dx - icon.width / 2, o.dy - icon.height / 2));
    });
  }

  /// "3 min slower" / "Similar ETA" on another way.
  static Future<ui.Image> label(double dpr, String text, {bool dark = false}) {
    final t = _text(text, 14, dark ? Colors.white : const Color(0xFF202124), weight: FontWeight.w500);
    final w = t.width + 22, h = t.height + 14;
    return _paint(w + 4, h + 4, dpr, (c) {
      final r = RRect.fromRectAndRadius(Rect.fromLTWH(2, 2, w, h), const Radius.circular(8));
      c.drawRRect(r.shift(const Offset(0, 1.5)), Paint()
        ..color = const Color(0x55000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5));
      c.drawRRect(r, Paint()..color = dark ? const Color(0xFF3C4043) : Colors.white);
      t.paint(c, Offset(2 + 11, 2 + 7));
    });
  }

  /// The navigation arrow as a map picture (used when the map isn't following it).
  static Future<ui.Image> arrow(double dpr) {
    const s = 56.0;
    return _paint(s, s, dpr, (c) => paintArrow(c, const Size(s, s)));
  }

  /// Google-Maps-style chevron: blue, white edge, soft shadow, on a faint blue disc.
  static void paintArrow(Canvas c, Size size) {
    final w = size.width, h = size.height;
    final o = Offset(w / 2, h / 2);
    c.drawCircle(o, w * 0.46, Paint()..color = const Color(0x332F80ED));
    final p = Path()
      ..moveTo(o.dx, h * 0.14)
      ..lineTo(w * 0.80, h * 0.80)
      ..lineTo(o.dx, h * 0.64)
      ..lineTo(w * 0.20, h * 0.80)
      ..close();
    c.drawPath(p.shift(const Offset(0, 2)), Paint()
      ..color = const Color(0x66000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    c.drawPath(p, Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.07
      ..strokeJoin = StrokeJoin.round);
    c.drawPath(p, Paint()..color = const Color(0xFF3B78F6));
  }

  /// Google's own night look for the map, used in the evening.
  static const nightStyle = '''
[
  {"elementType":"geometry","stylers":[{"color":"#1d2c4d"}]},
  {"elementType":"labels.text.fill","stylers":[{"color":"#8ec3b9"}]},
  {"elementType":"labels.text.stroke","stylers":[{"color":"#1a3646"}]},
  {"featureType":"administrative.country","elementType":"geometry.stroke","stylers":[{"color":"#4b6878"}]},
  {"featureType":"administrative.land_parcel","elementType":"labels.text.fill","stylers":[{"color":"#64779e"}]},
  {"featureType":"landscape.man_made","elementType":"geometry.stroke","stylers":[{"color":"#334e87"}]},
  {"featureType":"landscape.natural","elementType":"geometry","stylers":[{"color":"#023e58"}]},
  {"featureType":"poi","elementType":"geometry","stylers":[{"color":"#283d6a"}]},
  {"featureType":"poi","elementType":"labels.text.fill","stylers":[{"color":"#6f9ba5"}]},
  {"featureType":"poi","elementType":"labels.text.stroke","stylers":[{"color":"#1d2c4d"}]},
  {"featureType":"poi.park","elementType":"geometry.fill","stylers":[{"color":"#023e58"}]},
  {"featureType":"poi.park","elementType":"labels.text.fill","stylers":[{"color":"#3C7680"}]},
  {"featureType":"road","elementType":"geometry","stylers":[{"color":"#304a7d"}]},
  {"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#98a5be"}]},
  {"featureType":"road","elementType":"labels.text.stroke","stylers":[{"color":"#1d2c4d"}]},
  {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#2c6675"}]},
  {"featureType":"road.highway","elementType":"geometry.stroke","stylers":[{"color":"#255763"}]},
  {"featureType":"road.highway","elementType":"labels.text.fill","stylers":[{"color":"#b0d5ce"}]},
  {"featureType":"road.highway","elementType":"labels.text.stroke","stylers":[{"color":"#023e58"}]},
  {"featureType":"transit","elementType":"labels.text.fill","stylers":[{"color":"#98a5be"}]},
  {"featureType":"transit","elementType":"labels.text.stroke","stylers":[{"color":"#1d2c4d"}]},
  {"featureType":"transit.line","elementType":"geometry.fill","stylers":[{"color":"#283d6a"}]},
  {"featureType":"transit.station","elementType":"geometry","stylers":[{"color":"#3a4762"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#0e1626"}]},
  {"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#4e6d70"}]}
]''';
}

/// The arrow drawn over the map where the camera keeps it (lower middle), lying flat on the tilted map.
class NavArrow extends StatelessWidget {
  const NavArrow({super.key, this.turn = 0, this.tilt = 0.9});

  final double turn; // degrees, relative to the screen
  final double tilt; // radians the map is tipped back

  @override
  Widget build(BuildContext context) {
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..setEntry(3, 2, 0.0018)
        ..rotateX(tilt)
        ..rotateZ(turn * math.pi / 180),
      child: const CustomPaint(size: Size(64, 64), painter: _ArrowPainter()),
    );
  }
}

class _ArrowPainter extends CustomPainter {
  const _ArrowPainter();

  @override
  void paint(Canvas canvas, Size size) => NavIcons.paintArrow(canvas, size);

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
