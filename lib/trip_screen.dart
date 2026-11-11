import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'app_theme.dart';
import 'erp_service.dart';
import 'map_tiles.dart';
import 'nav_icons.dart';
import 'preferences.dart';
import 'stop_actions.dart';
import 'voice_guide.dart';

/// The trip in progress: a full-screen map with the road route through the stops still to visit,
/// the next turn, distance and arrival time, and each stop ticking to "Reached" as the phone gets there.
class TripScreen extends StatefulWidget {
  const TripScreen({super.key, required this.planName});

  final String planName;

  @override
  State<TripScreen> createState() => _TripScreenState();
}

class _TripScreenState extends State<TripScreen> with SingleTickerProviderStateMixin {
  static const _offRoute = 60.0; // metres from the route before it is worked out again
  // Google's map (tilted 3D, Google's roads and look) when the app was built with a Maps key,
  // else the OpenStreetMap one
  static const _google = bool.fromEnvironment('GMAPS');
  static const _tiltDeg = 45.0;

  /// How close counts as "arrived": at the stop, not across the road (looser when GPS is poor).
  double _arriveWithin(Position p) => (p.accuracy + 12).clamp(25.0, 50.0).toDouble();

  final _map = MapController();
  gm.GoogleMapController? _gmap;
  double _bearing = 0; // Google camera bearing, degrees
  DateTime _lastCam = DateTime.fromMillisecondsSinceEpoch(0);
  Offset? _downAt; // finger down on the map (moving it stops following)
  DateTime _lastFixAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _mapReady = false;
  bool _follow = true;
  bool _satellite = false;
  String _theme = 'auto'; // map: auto (dark from 6:30 pm to 6 am), light or dark

  TripPlan? _plan;
  List<List<double>> _track = const [];
  String? _loadError;

  Position? _pos;
  StreamSubscription<Position>? _gps;
  String? _gpsProblem;

  RoutePlan? _route; // the way being followed, to the next stop only
  List<RoutePlan> _alts = const []; // other ways to the same stop, shown in grey with how much slower they are
  List<LatLng?> _altLabelAt = const [];
  Timer? _refresh; // fresh traffic times and alternatives every few minutes
  bool _skipping = false;
  List<double> _cum = const []; // distance along the route to each line point
  List<int> _stepAt = const []; // line point of each step
  List<PlanStop> _routedStops = const [];
  String _routedKey = ''; // where the current route goes
  FuelStation? _detour; // going to a petrol pump first, then on to the next stop
  List<FuelStation> _pumps = const []; // petrol pumps on the way, shown on the map
  int _userAt = 0;
  bool _routing = false;
  DateTime _routedAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _routeError;

  final Set<int> _reachedHere = {}; // stops the phone has just reached (before the ERP confirms)
  String? _banner;
  bool _panelOpen = false; // bottom panel: compact (next stop only) or open (all stops and buttons)
  Timer? _bannerTimer;
  Timer? _poll;

  final _voice = VoiceGuide();

  // Google-Maps-like motion: the arrow glides between GPS fixes, the map turns so the way ahead is up,
  // zooms out as speed rises, and keeps the arrow in the lower part of the screen.
  late final AnimationController _glide =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 950))..addListener(_onGlide);
  LatLng? _shown; // where the arrow is drawn right now
  LatLng? _glideFrom;
  LatLng? _glideTo;
  double _heading = 0; // degrees, 0 = north
  double _headingFrom = 0;
  double _headingTo = 0;
  bool _moving = false;
  DateTime _lastMoving = DateTime.fromMillisecondsSinceEpoch(0);
  LatLng? _lastFix;
  bool _headingUp = true; // map turns with the direction of travel (compass button switches to north up)
  double _zoom = 17;
  double _screenH = 700;
  int _spokenStep = -1; // step index the last announcement was about
  int _spokenStage = 0; // 1 = far ahead, 2 = coming up, 3 = now
  bool _greeted = false;
  bool _offRouteReroute = false;
  bool _saidAllDone = false;

  @override
  void initState() {
    super.initState();
    _voice.init();
    try {
      _theme = Preferences.instance.getString(Preferences.tripMapTheme) ?? 'auto';
    } catch (_) {}
    WakelockPlus.enable().catchError((_) {});
    _load();
    _startGps();
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => _load());
    _refresh = Timer.periodic(const Duration(minutes: 4), (_) {
      if (_route != null && !_routing) _reroute(quiet: true);
    });
  }

  @override
  void dispose() {
    _gps?.cancel();
    _poll?.cancel();
    _refresh?.cancel();
    _bannerTimer?.cancel();
    _voice.stop();
    _glide.dispose();
    WakelockPlus.disable().catchError((_) {});
    super.dispose();
  }

  // ---------------------------------------------------------------------------------------------
  // data

  Future<void> _load() async {
    try {
      final day = await ErpService.myDay(days: 1);
      final plan = day.plans.where((p) => p.name == widget.planName).firstOrNull ?? day.plans.firstOrNull;
      if (!mounted) return;
      final before = _remaining().map((s) => s.idx).join(',');
      setState(() {
        _plan = plan;
        _track = day.track;
        _loadError = plan == null ? 'This trip is no longer planned for today.' : null;
      });
      if (_remaining().map((s) => s.idx).join(',') != before || _route == null) _reroute();
    } catch (e) {
      if (mounted && _plan == null) setState(() => _loadError = '$e');
    }
  }

  /// Status as the ERP says, but "Reached" straight away when the phone is there.
  String _status(PlanStop s) => s.pending && _reachedHere.contains(s.idx) ? 'Reached' : s.status;

  List<PlanStop> _remaining() =>
      (_plan?.stops ?? const <PlanStop>[]).where((s) => _status(s) == 'Pending' && s.hasLocation).toList();

  Future<void> _startGps() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        setState(() => _gpsProblem = 'Turn on location to follow the route.');
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        if (mounted) setState(() => _gpsProblem = 'Allow location for HiperTracker to follow the route.');
        return;
      }
      // a fix every second, like a car navigator (no distance filter, so slow traffic still moves the arrow)
      final settings = defaultTargetPlatform == TargetPlatform.android
          ? AndroidSettings(
              accuracy: LocationAccuracy.bestForNavigation,
              distanceFilter: 0,
              intervalDuration: const Duration(milliseconds: 1000),
            )
          : const LocationSettings(accuracy: LocationAccuracy.bestForNavigation, distanceFilter: 0);
      _gps = Geolocator.getPositionStream(locationSettings: settings).listen(_onPosition, onError: (_) {
        if (mounted) setState(() => _gpsProblem = 'Waiting for GPS…');
      });
    } catch (_) {
      if (mounted) setState(() => _gpsProblem = 'Waiting for GPS…');
    }
  }

  void _onPosition(Position p) {
    if (!mounted) return;
    final first = _pos == null;
    _pos = p;
    _gpsProblem = null;

    // reached the petrol pump? then on to the next stop
    final pump = _detour;
    if (pump != null && p.accuracy <= 60 &&
        Geolocator.distanceBetween(p.latitude, p.longitude, pump.lat, pump.lon) <= _arriveWithin(p) + 10) {
      _detour = null;
      HapticFeedback.heavyImpact();
      _showBanner('Reached ${pump.name}');
      final nxt = _remaining().firstOrNull;
      _voice.say('You have arrived at ${pump.name}.${nxt == null ? '' : ' Resuming route to ${nxt.name}.'}');
      _reroute();
    }

    // reached the next stop?
    final rem = _remaining();
    if (rem.isNotEmpty && p.accuracy <= 60) {
      final next = rem.first;
      if (Geolocator.distanceBetween(p.latitude, p.longitude, next.lat!, next.lon!) <= _arriveWithin(p)) {
        final side = _sideOf(next.lat!, next.lon!);
        _reachedHere.add(next.idx);
        HapticFeedback.heavyImpact();
        _showBanner('Reached ${next.name}');
        final after = _remaining().firstOrNull;
        final here = 'You have arrived at ${next.name}${side == null ? '' : ', on your $side'}.';
        _voice.say(after == null
            ? '$here This was your last stop. All stops are complete.'
            : '$here Your next stop is ${after.name}.');
        _saidAllDone = after == null;
        _reroute();
        unawaited(_load());
      }
    }

    // where on the route are we, and have we left it?
    if (_route != null && _route!.line.isNotEmpty) {
      var best = 0;
      var bestD = double.infinity;
      final line = _route!.line;
      for (var i = 0; i < line.length; i++) {
        final d = Geolocator.distanceBetween(p.latitude, p.longitude, line[i][0], line[i][1]);
        if (d < bestD) {
          bestD = d;
          best = i;
        }
      }
      _userAt = best;
      if (bestD > 35 && _alts.isNotEmpty && _switchToAlternative(p)) {
        // took one of the other ways: follow it, like Google Maps does
      } else if (bestD > _offRoute && DateTime.now().difference(_routedAt).inSeconds > 20) {
        _offRouteReroute = true;
        _reroute();
      }
    }
    if (first || _route == null) _reroute();
    _speakDirections();

    _startGlide(p);
    setState(() {});
  }

  /// Moving or stopped, which way we're heading, and glide the arrow to the new fix.
  void _startGlide(Position p) {
    final here = LatLng(p.latitude, p.longitude);
    final speed = p.speed.isFinite ? p.speed : 0.0; // m/s
    if (speed > 1.4) _lastMoving = DateTime.now();
    _moving = DateTime.now().difference(_lastMoving).inSeconds < 4;

    var heading = _headingTo;
    if (speed > 1.4 && p.heading.isFinite && p.heading >= 0) {
      heading = p.heading;
    } else if (_lastFix != null &&
        Geolocator.distanceBetween(_lastFix!.latitude, _lastFix!.longitude, here.latitude, here.longitude) > 8) {
      heading = Geolocator.bearingBetween(_lastFix!.latitude, _lastFix!.longitude, here.latitude, here.longitude);
    }
    if (_lastFix == null ||
        Geolocator.distanceBetween(_lastFix!.latitude, _lastFix!.longitude, here.latitude, here.longitude) > 8) {
      _lastFix = here;
    }
    heading = (heading % 360 + 360) % 360;

    // keep up with the car: aim where it will be when the next fix comes, on the road of the route
    var target = here;
    if (_moving && speed > 1.4) {
      target = _offsetBy(here, heading, math.min(speed * 0.9, 25));
    }
    final snap = _snap(target);
    if (snap != null) {
      target = snap.$1;
      if (_moving) heading = snap.$2;
    }
    heading = (heading % 360 + 360) % 360;

    // zoom by speed, like a car navigator
    final kmh = speed * 3.6;
    final targetZoom = _google
        ? (!_moving ? 15.6 : kmh < 20 ? 16.6 : kmh < 45 ? 16.0 : kmh < 70 ? 15.4 : 14.8) // Google Maps' own levels
        : (!_moving ? 17.2 : kmh < 15 ? 17.5 : kmh < 35 ? 16.8 : kmh < 60 ? 16.1 : 15.4);
    _zoom = _zoom + (targetZoom - _zoom) * 0.35;

    _glideFrom = _shown ?? target;
    _glideTo = target;
    // glide over the time between fixes, so the arrow never stops between them
    final now = DateTime.now();
    final gap = now.difference(_lastFixAt).inMilliseconds;
    _lastFixAt = now;
    _glide.duration = Duration(milliseconds: gap.clamp(500, 1500));
    _headingFrom = _heading;
    // turn the short way round
    var delta = heading - _headingFrom;
    if (delta > 180) delta -= 360;
    if (delta < -180) delta += 360;
    _headingTo = _headingFrom + delta;
    _glide.forward(from: 0);
  }

  /// [d] metres from [p] towards [bearing].
  LatLng _offsetBy(LatLng p, double bearing, double d) {
    final b = bearing * math.pi / 180;
    final dLat = d * math.cos(b) / 111320.0;
    final dLon = d * math.sin(b) / (111320.0 * math.cos(p.latitude * math.pi / 180));
    return LatLng(p.latitude + dLat, p.longitude + dLon);
  }

  /// [p] put onto the route's road when it's within 20 m of it: (point on the road, road direction).
  (LatLng, double)? _snap(LatLng p) {
    final line = _route?.line;
    if (line == null || line.length < 2) return null;
    final k = math.cos(p.latitude * math.pi / 180) * 111320.0;
    const m = 111320.0;
    (LatLng, double)? best;
    var bestD = 20.0;
    final from = math.max(0, _userAt - 8), to = math.min(line.length - 1, _userAt + 60);
    for (var i = from; i < to; i++) {
      final ax = line[i][1] * k, ay = line[i][0] * m, bx = line[i + 1][1] * k, by = line[i + 1][0] * m;
      final px = p.longitude * k, py = p.latitude * m;
      final dx = bx - ax, dy = by - ay;
      final len = dx * dx + dy * dy;
      if (len < 0.01) continue;
      final t = (((px - ax) * dx + (py - ay) * dy) / len).clamp(0.0, 1.0);
      final qx = ax + dx * t, qy = ay + dy * t;
      final d = math.sqrt((px - qx) * (px - qx) + (py - qy) * (py - qy));
      if (d < bestD) {
        bestD = d;
        final brg = (math.atan2(dx, dy) * 180 / math.pi + 360) % 360;
        best = (LatLng(qy / m, qx / k), brg);
      }
    }
    return best;
  }

  /// Which side of the road the stop is, going along the route: "left", "right" or null (ahead).
  String? _sideOf(double lat, double lon) {
    final line = _route?.line;
    if (line == null || line.length < 2) return null;
    final a = line[line.length - 2], b = line.last;
    final k = math.cos(lat * math.pi / 180);
    final dx = (b[1] - a[1]) * k, dy = b[0] - a[0];
    final ex = (lon - b[1]) * k, ey = lat - b[0];
    if (math.sqrt(ex * ex + ey * ey) * 111320 < 6) return null;
    final cross = dx * ey - dy * ex;
    return cross > 0 ? 'left' : 'right';
  }

  void _onGlide() {
    final a = _glideFrom, b = _glideTo;
    if (a == null || b == null) return;
    final t = _glide.value; // straight through: no slowing down at each fix
    _shown = LatLng(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t);
    _heading = _headingFrom + (_headingTo - _headingFrom) * t;
    if (_follow && _mapReady) {
      if (_google) {
        final now = DateTime.now();
        if (now.difference(_lastCam).inMilliseconds >= 25) {
          _lastCam = now;
          if (_headingUp && _moving) _bearing = _heading;
          if (!_headingUp) _bearing = 0;
          _gmap?.moveCamera(gm.CameraUpdate.newCameraPosition(gm.CameraPosition(
            target: gm.LatLng(_shown!.latitude, _shown!.longitude),
            zoom: _zoom,
            bearing: _bearing,
            tilt: _headingUp ? _tiltDeg : 0,
          )));
        }
      } else {
        final rotation = _headingUp ? (_moving ? -_heading : _map.camera.rotation) : 0.0;
        _map.rotate(rotation);
        _map.move(_shown!, _zoom, offset: Offset(0, _headingUp ? _screenH * 0.2 : 0));
      }
    }
    if (mounted) setState(() {});
  }

  /// Degrees the map is turned (for the compass button).
  double _mapTurn() => _google ? -_bearing : (_mapReady ? _map.camera.rotation : 0);

  void _camTo(LatLng at, double zoom) {
    if (_google) {
      _gmap?.animateCamera(gm.CameraUpdate.newCameraPosition(
          gm.CameraPosition(target: gm.LatLng(at.latitude, at.longitude), zoom: zoom, bearing: _bearing)));
    } else {
      _map.move(at, zoom);
    }
  }

  void _camFit(List<LatLng> pts, EdgeInsets pad) {
    if (pts.isEmpty) return;
    if (pts.length == 1) {
      _camTo(pts.first, 15);
      return;
    }
    if (_google) {
      var s = pts.first.latitude, n = s, w = pts.first.longitude, e = w;
      for (final p in pts) {
        s = math.min(s, p.latitude);
        n = math.max(n, p.latitude);
        w = math.min(w, p.longitude);
        e = math.max(e, p.longitude);
      }
      _bearing = 0;
      _gmap?.animateCamera(gm.CameraUpdate.newLatLngBounds(
          gm.LatLngBounds(southwest: gm.LatLng(s, w), northeast: gm.LatLng(n, e)), 70));
    } else {
      _map.rotate(0);
      _map.fitCamera(CameraFit.coordinates(coordinates: pts, padding: pad));
    }
  }

  void _recenter() {
    setState(() => _follow = true);
    final at = _shown ?? (_pos != null ? LatLng(_pos!.latitude, _pos!.longitude) : null);
    if (at != null && _mapReady) {
      if (_google) {
        if (_headingUp) _bearing = _heading;
        _gmap?.animateCamera(gm.CameraUpdate.newCameraPosition(gm.CameraPosition(
          target: gm.LatLng(at.latitude, at.longitude),
          zoom: _zoom,
          bearing: _headingUp ? _bearing : 0,
          tilt: _headingUp ? _tiltDeg : 0,
        )));
      } else {
        _map.rotate(_headingUp && _moving ? -_heading : (_headingUp ? _map.camera.rotation : 0));
        _map.move(at, _zoom, offset: Offset(0, _headingUp ? _screenH * 0.2 : 0));
      }
    }
  }

  /// Distance along [r] to each of its points, and the point of each step.
  (List<double>, List<int>) _measure(RoutePlan r) {
    final cum = <double>[0];
    for (var i = 1; i < r.line.length; i++) {
      cum.add(cum[i - 1] + Geolocator.distanceBetween(r.line[i - 1][0], r.line[i - 1][1], r.line[i][0], r.line[i][1]));
    }
    // each step's place on the line (steps come in order, so search forwards)
    final at = <int>[];
    var from0 = 0;
    for (final s in r.steps) {
      var best = from0;
      var bestD = double.infinity;
      for (var i = from0; i < r.line.length; i++) {
        final d = Geolocator.distanceBetween(s.lat, s.lon, r.line[i][0], r.line[i][1]);
        if (d < bestD) {
          bestD = d;
          best = i;
        }
        if (d < 1) break;
      }
      at.add(best);
      from0 = best;
    }
    return (cum, at);
  }

  /// Nearest point of [line] to [lat], [lon]: (index, metres).
  (int, double) _nearest(List<List<double>> line, double lat, double lon, {int step = 1}) {
    var best = 0;
    var bestD = double.infinity;
    for (var i = 0; i < line.length; i += step) {
      final d = Geolocator.distanceBetween(lat, lon, line[i][0], line[i][1]);
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return (best, bestD);
  }

  /// Where to put an alternative's "3 min slower" label: its point furthest from the main route.
  LatLng? _labelPoint(RoutePlan alt, RoutePlan main) {
    if (alt.line.length < 2) return null;
    LatLng? at;
    var far = 0.0;
    final step = math.max(1, alt.line.length ~/ 80);
    for (var i = 0; i < alt.line.length; i += step) {
      final d = _nearest(main.line, alt.line[i][0], alt.line[i][1], step: math.max(1, main.line.length ~/ 150)).$2;
      if (d > far) {
        far = d;
        at = LatLng(alt.line[i][0], alt.line[i][1]);
      }
    }
    return far > 60 ? at : null;
  }

  void _use(RoutePlan r, List<RoutePlan> alts, {bool keepVoice = false}) {
    final (cum, at) = _measure(r);
    // keep what was already said about the next turn when only the traffic times changed
    final old = _route != null && _spokenStep >= 0 && _spokenStep < _route!.steps.length ? _route!.steps[_spokenStep] : null;
    _route = r;
    _alts = alts;
    _altLabelAt = [for (final a in alts) _labelPoint(a, r)];
    _cum = cum;
    _stepAt = at;
    _userAt = _pos == null ? 0 : _nearest(r.line, _pos!.latitude, _pos!.longitude).$1;
    _routedAt = DateTime.now();
    _routeError = null;
    final same = keepVoice && old != null
        ? r.steps.indexWhere((s) => s.type == old.type && Geolocator.distanceBetween(s.lat, s.lon, old.lat, old.lon) < 20)
        : -1;
    if (same >= 0) {
      _spokenStep = same;
    } else {
      _spokenStep = -1;
      _spokenStage = 0;
    }
  }

  /// On one of the other ways? Follow it instead (the old way becomes an alternative).
  bool _switchToAlternative(Position p) {
    final main = _route;
    if (main == null) return false;
    for (var k = 0; k < _alts.length; k++) {
      final a = _alts[k];
      final (_, d) = _nearest(a.line, p.latitude, p.longitude);
      if (d <= 30) {
        final others = [main, for (var j = 0; j < _alts.length; j++) if (j != k) _alts[j]];
        _use(a, others);
        _voice.say('Following the alternate route.');
        return true;
      }
    }
    return false;
  }

  Future<void> _reroute({bool quiet = false}) async {
    if (_routing) return;
    final rem = _remaining();
    final from = _pos != null
        ? [_pos!.latitude, _pos!.longitude]
        : (_track.isNotEmpty ? _track.last : null);
    if (rem.isEmpty || from == null) {
      if (!mounted) return;
      setState(() {
        _route = null;
        _alts = const [];
        _routedStops = const [];
      });
      return;
    }
    _routing = true;
    try {
      // only the way to the next stop: the stops after it come one at a time, in the planned order
      final stops = rem.take(1).toList();
      final pump = _detour;
      final heading = _moving && _pos != null && _pos!.heading.isFinite && _pos!.heading >= 0 ? _pos!.heading : null;
      final r = await ErpService.route(
          from, pump != null ? [[pump.lat, pump.lon]] : [for (final s in stops) [s.lat!, s.lon!]],
          heading: heading);
      if (!mounted) return;
      final key = pump != null ? 'pump ${pump.lat},${pump.lon}' : 'stop ${stops.first.idx}';
      final sameStop = key == _routedKey;
      setState(() {
        _use(r, r.alternatives, keepVoice: quiet && sameStop);
        _routedStops = stops;
        _routedKey = key;
      });
      if (!_greeted) {
        _greeted = true;
        final to = r.legs.isNotEmpty ? r.legs.first[0].toDouble() : r.distance.toDouble();
        _voice.say('Starting route to ${_destName() ?? stops.first.name}. ${VoiceGuide.distance(to)} to go.');
      } else if (_offRouteReroute) {
        _voice.say('Rerouting.');
      }
      _offRouteReroute = false;
      if (_follow && _mapReady && _pos == null) _fitAll();
    } catch (e) {
      if (mounted && !quiet) setState(() => _routeError = 'Route not available right now');
    } finally {
      _routing = false;
    }
  }

  /// The way ahead as points, for looking along it.
  List<List<double>> _ahead() {
    final r = _route;
    final pts = <List<double>>[if (_pos != null) [_pos!.latitude, _pos!.longitude]];
    if (r != null) pts.addAll(r.line.skip(_userAt));
    return pts;
  }

  void _goToPump(FuelStation f) {
    setState(() {
      _detour = f;
      _follow = true;
    });
    _voice.say('Going to ${f.name} first.');
    _reroute();
  }

  void _cancelPump() {
    setState(() => _detour = null);
    final nxt = _remaining().firstOrNull;
    if (nxt != null) _voice.say('Resuming route to ${nxt.name}.');
    _reroute();
  }

  Future<void> _showPumps() async {
    final pts = _ahead();
    if (pts.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Waiting for the route…')));
      return;
    }
    final future = ErpService.fuelStations(pts);
    future.then((list) {
      if (mounted) setState(() => _pumps = list);
    }).catchError((_) {});
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.55,
        maxChildSize: 0.9,
        builder: (ctx, scroll) => FutureBuilder<List<FuelStation>>(
          future: future,
          builder: (ctx, snap) {
            final header = Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(children: [
                const Icon(Icons.local_gas_station, color: Color(0xFFE37400)),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text('Petrol pumps on your way', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                ),
                if (_detour != null)
                  TextButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _cancelPump();
                    },
                    child: const Text('Cancel pump stop'),
                  ),
              ]),
            );
            if (snap.connectionState != ConnectionState.done) {
              return ListView(controller: scroll, children: [
                header,
                const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
              ]);
            }
            final here = _pos;
            double crow(FuelStation f) =>
                here == null ? 0 : Geolocator.distanceBetween(here.latitude, here.longitude, f.lat, f.lon);
            final list = [...(snap.data ?? const <FuelStation>[])]
              ..sort((a, b) => (a.metres?.toDouble() ?? crow(a)).compareTo(b.metres?.toDouble() ?? crow(b)));
            return ListView.separated(
              controller: scroll,
              itemCount: list.length + 1,
              separatorBuilder: (_, i) => i == 0 ? const SizedBox.shrink() : const Divider(height: 1, indent: 72),
              itemBuilder: (ctx, i) {
                if (i == 0) {
                  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    header,
                    if (snap.hasError)
                      Padding(padding: const EdgeInsets.all(20), child: Text('${snap.error}'))
                    else if (list.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(20),
                        child: Text('No petrol pumps found along the way to your next stop.'),
                      ),
                  ]);
                }
                final f = list[i - 1];
                final far = f.metres != null ? _dist(f.metres!.toDouble()) : (here == null ? '' : '${_dist(crow(f))} away');
                final info = [
                  if (far.isNotEmpty) far,
                  if (f.seconds != null) _mins(f.seconds!.toDouble()),
                  if (f.open == true) 'Open now',
                  if (f.open == false) 'Closed',
                ].join(' · ');
                return ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFFFF1E0),
                    child: Icon(Icons.local_gas_station, color: Color(0xFFE37400)),
                  ),
                  title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text([info, if (f.address.isNotEmpty) f.address].join('\n'),
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: f.open == false ? HsColors.danger : HsColors.textSecondary)),
                  trailing: FilledButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _goToPump(f);
                    },
                    child: const Text('Go'),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(() => _follow = false);
                    if (_mapReady) _camTo(LatLng(f.lat, f.lon), 16);
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }

  Future<void> _skip(PlanStop s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Skip ${s.name}?'),
        content: const Text('Stops are reached in the planned order. Skip this one to go on to the next stop.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Skip stop')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _skipping = true);
    try {
      await ErpService.skipMyStop(_plan!.name, s.idx);
      _showBanner('Skipped ${s.name}');
      await _load();
      _reroute();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _skipping = false);
    }
  }

  void _showBanner(String text) {
    _bannerTimer?.cancel();
    setState(() => _banner = text);
    _bannerTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _banner = null);
    });
  }

  void _fitAll() {
    final pts = <LatLng>[
      for (final s in _plan?.stops ?? const <PlanStop>[]) if (s.hasLocation) LatLng(s.lat!, s.lon!),
      if (_pos != null) LatLng(_pos!.latitude, _pos!.longitude),
    ];
    _camFit(pts, const EdgeInsets.fromLTRB(40, 160, 40, 260));
  }

  // ---------------------------------------------------------------------------------------------
  // what to show

  /// The next instruction: [step, metres to it, index].
  (RouteStep, double, int)? _nextStep() {
    final r = _route;
    if (r == null || r.steps.isEmpty || _cum.isEmpty) return null;
    for (var i = 0; i < r.steps.length; i++) {
      final s = r.steps[i];
      if (s.type == 'depart') continue;
      if (_stepAt[i] > _userAt) return (s, math.max(0, _cum[_stepAt[i]] - _cum[_userAt]), i);
    }
    return null;
  }

  /// The turn straight after the next one, when it comes soon after it ("Then ↱").
  RouteStep? _thenStep(int i) {
    final r = _route;
    if (r == null || i + 1 >= r.steps.length) return null;
    final gap = _cum[_stepAt[i + 1]] - _cum[_stepAt[i]];
    return gap <= 150 ? r.steps[i + 1] : null;
  }

  /// The road of an instruction ("Turn right onto Bank Rd" -> "Bank Rd"), or null.
  String? _road(String text) => _roadParts(text)?.$2;

  /// The road I'm on now (from the last instruction passed), shown at the bottom like Google.
  String? _currentRoad() {
    final r = _route;
    if (r == null || _stepAt.length != r.steps.length) return null;
    String? road;
    for (var i = 0; i < r.steps.length; i++) {
      if (_stepAt[i] > _userAt) break;
      final p = _roadParts(_stepText(r.steps[i]));
      if (p != null && p.$1.isEmpty) road = p.$2; // "onto X", "on X": now on X
    }
    return road;
  }

  /// ("toward", "V K Krishna Menon Rd") from "Head north toward V K Krishna Menon Rd".
  (String, String)? _roadParts(String text) {
    final m = RegExp(r'\b(onto|on|toward|towards|to stay on|into)\s+(.+)$', caseSensitive: false).firstMatch(text);
    if (m == null) return null;
    final prep = m.group(1)!.toLowerCase();
    return (prep == 'towards' ? 'toward' : (prep == 'onto' || prep == 'on' || prep == 'into' ? '' : prep), m.group(2)!.trim());
  }

  /// Road name with "Rd", "St" ... smaller, like Google's banner.
  InlineSpan _roadSpan(String prep, String road, double size) {
    final parts = <InlineSpan>[
      if (prep.isNotEmpty)
        TextSpan(text: '$prep ', style: TextStyle(fontSize: size * 0.55, fontWeight: FontWeight.w500)),
    ];
    final re = RegExp(r'\b(Rd|St|Ave|Hwy|Ln|Jn|Byp)\b');
    var at = 0;
    for (final m in re.allMatches(road)) {
      parts.add(TextSpan(text: road.substring(at, m.start)));
      parts.add(TextSpan(text: m.group(0), style: TextStyle(fontSize: size * 0.6, fontWeight: FontWeight.w600)));
      at = m.end;
    }
    parts.add(TextSpan(text: road.substring(at)));
    return TextSpan(children: parts);
  }

  /// Announce the next turn: once well before it, once when it's coming up, and when it's here.
  void _speakDirections() {
    final r = _route;
    if (r == null || _pos == null || _cum.isEmpty) return;
    if (_remaining().isEmpty) {
      if (!_saidAllDone) {
        _saidAllDone = true;
        _voice.say('All stops are complete.');
      }
      return;
    }
    for (var i = 0; i < r.steps.length; i++) {
      final s = r.steps[i];
      if (s.type == 'depart' || _stepAt[i] <= _userAt) continue;
      final d = math.max(0.0, _cum[_stepAt[i]] - _cum[_userAt]);
      if (i != _spokenStep) {
        _spokenStep = i;
        _spokenStage = 0;
      }
      final text = _spokenText(s);
      if (d <= 40 && _spokenStage < 3) {
        _spokenStage = 3;
        _voice.say(s.type == 'arrive'
            ? '${_arriveName(s)} is ahead.'
            : text.isEmpty
                ? ''
                : '${text[0].toUpperCase()}${text.substring(1)}.');
      } else if (d <= 250 && d > 40 && _spokenStage < 2) {
        _spokenStage = 2;
        _voice.say('In ${VoiceGuide.distance(d)}, $text.');
      } else if (d <= 1500 && d > 250 && _spokenStage < 1) {
        _spokenStage = 1;
        _voice.say('In ${VoiceGuide.distance(d)}, $text.');
      } else if (d > 1500 && _spokenStage < 1) {
        _spokenStage = 1;
        _voice.say('Continue straight for ${VoiceGuide.distance(d)}.');
      }
      return;
    }
  }

  /// Where the route ends: the petrol pump being driven to, or the next stop.
  String? _destName() => _detour?.name ?? (_routedStops.isNotEmpty ? _routedStops.first.name : null);

  String _arriveName(RouteStep s) {
    final n = _destName() ?? 'Your stop';
    final stop = _detour == null && _routedStops.isNotEmpty ? _routedStops.first : null;
    final side = stop == null ? null : _sideOf(stop.lat!, stop.lon!);
    return side == null ? n : '$n, on your $side,';
  }

  String _spokenText(RouteStep s) {
    if (s.type == 'arrive') {
      final stop = _destName();
      return stop == null ? 'your stop is ahead' : '$stop is ahead';
    }
    final t = s.text;
    return t.isEmpty ? t : t[0].toLowerCase() + t.substring(1);
  }

  /// Distance (m) and time (s) to the next stop along the route.
  (double, double)? _toNext() {
    final r = _route;
    if (r == null || _cum.isEmpty || r.legs.isEmpty) return null;
    final arrive = [for (var i = 0; i < r.steps.length; i++) if (r.steps[i].type == 'arrive') _stepAt[i]];
    final end = arrive.isNotEmpty ? arrive.first : _cum.length - 1;
    final left = math.max(0.0, _cum[end] - _cum[math.min(_userAt, end)]);
    final leg = r.legs.first;
    final secs = leg[0] > 0 ? leg[1] * left / leg[0] : left / 8;
    return (left, secs);
  }

  String _dist(double m) => m >= 1000 ? '${(m / 1000).toStringAsFixed(m >= 10000 ? 0 : 1)} km' : '${(m / 10).round() * 10} m';

  String _mins(double s) {
    final m = (s / 60).round();
    return m >= 60 ? '${m ~/ 60} h ${m % 60} min' : '${math.max(m, 1)} min';
  }

  IconData _icon(RouteStep s) {
    if (s.type == 'arrive') return Icons.flag;
    if (s.type.contains('roundabout') || s.type == 'rotary') return Icons.roundabout_right;
    if (s.type == 'merge') return Icons.merge;
    if (s.type == 'fork') return s.modifier.contains('left') ? Icons.fork_left : Icons.fork_right;
    if (s.type == 'on ramp' || s.type == 'off ramp') return s.modifier.contains('left') ? Icons.ramp_left : Icons.ramp_right;
    switch (s.modifier) {
      case 'uturn':
        return Icons.u_turn_left;
      case 'sharp right':
        return Icons.turn_sharp_right;
      case 'right':
        return Icons.turn_right;
      case 'slight right':
        return Icons.turn_slight_right;
      case 'sharp left':
        return Icons.turn_sharp_left;
      case 'left':
        return Icons.turn_left;
      case 'slight left':
        return Icons.turn_slight_left;
    }
    return Icons.straight;
  }

  String _stepText(RouteStep s) {
    if (s.type == 'arrive') {
      final stop = _destName();
      return stop == null ? 'Arrive' : 'Arrive at $stop';
    }
    return s.text;
  }

  // ---------------------------------------------------------------------------------------------

  static const _navGreen = Color(0xFF0B5E5B); // Google Maps' instruction banner
  static const _navGreenDark = Color(0xFF07423F);

  Widget _roundButton({required IconData icon, required VoidCallback onTap, String? tip, Color? color, Widget? child}) {
    return Tooltip(
      message: tip ?? '',
      child: Material(
        color: Colors.white,
        shape: const CircleBorder(),
        elevation: 3,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(width: 54, height: 54, child: Center(child: child ?? Icon(icon, color: color ?? HsColors.charcoal, size: 26))),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _screenH = MediaQuery.of(context).size.height;
    final plan = _plan;
    final bottomPad = MediaQuery.of(context).padding.bottom;
    final kmh = _pos != null && _pos!.speed.isFinite ? math.max(0, _pos!.speed * 3.6).round() : null;
    return Scaffold(
      body: plan == null
          ? Center(
              child: _loadError == null
                  ? const CircularProgressIndicator()
                  : Padding(padding: const EdgeInsets.all(24), child: Text(_loadError!, textAlign: TextAlign.center)),
            )
          : Stack(children: [
              Positioned.fill(child: _mapView(plan)),
              if (_google && _follow && _shown != null) _arrowOverlay(),
              if (_follow && _currentRoad() != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 118 + MediaQuery.of(context).padding.bottom,
                  child: IgnorePointer(
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 6)],
                        ),
                        child: Text(_currentRoad()!,
                            style: const TextStyle(color: Color(0xFF0B1A6E), fontSize: 17, fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
                ),
              Positioned(left: 0, right: 0, top: 0, child: SafeArea(child: _topBar(plan))),
              Positioned(left: 0, right: 0, bottom: 0, child: _bottomPanel(plan)),
              AnimatedPositioned(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                right: 14,
                bottom: (_panelOpen ? 330 : 120) + bottomPad,
                child: Column(children: [
                  _roundButton(
                    icon: Icons.local_gas_station_outlined,
                    color: _detour != null ? const Color(0xFFE37400) : HsColors.charcoal,
                    tip: 'Petrol pumps on the way',
                    onTap: _showPumps,
                  ),
                  const SizedBox(height: 12),
                  _roundButton(
                    icon: Icons.navigation,
                    tip: _headingUp ? 'North up' : 'Direction of travel up',
                    onTap: () {
                      setState(() => _headingUp = !_headingUp);
                      if (!_headingUp && _mapReady && !_google) _map.rotate(0);
                      _recenter();
                    },
                    child: Transform.rotate(
                      angle: _mapTurn() * math.pi / 180,
                      child: const Icon(Icons.navigation, color: Color(0xFFD93025), size: 28),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _roundButton(
                    icon: _voice.enabled ? Icons.volume_up_outlined : Icons.volume_off_outlined,
                    color: _voice.enabled ? HsColors.charcoal : HsColors.danger,
                    tip: _voice.enabled ? 'Mute voice' : 'Voice on',
                    onTap: () {
                      setState(() => _voice.enabled = !_voice.enabled);
                      if (_voice.enabled) _voice.say('Voice guidance on.');
                    },
                  ),
                  const SizedBox(height: 12),
                  _roundButton(
                    icon: Icons.alt_route,
                    tip: 'Route overview',
                    onTap: () {
                      setState(() => _follow = false);
                      _fitRoute();
                    },
                  ),
                  const SizedBox(height: 12),
                  _roundButton(
                    icon: Icons.layers_outlined,
                    tip: 'Map look',
                    onTap: _mapLook,
                  ),
                ]),
              ),
              if (kmh != null)
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  left: 14,
                  bottom: (_panelOpen ? 330 : 120) + bottomPad + (_google ? 34 : 0), // Google logo stays visible
                  child: Material(
                    color: Colors.white,
                    shape: const CircleBorder(),
                    elevation: 3,
                    child: SizedBox(
                      width: 64,
                      height: 64,
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Text('$kmh', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, height: 1)),
                        const Text('km/h', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                      ]),
                    ),
                  ),
                ),
              if (!_follow)
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 250),
                  left: 0,
                  right: 0,
                  bottom: (_panelOpen ? 330 : 120) + bottomPad,
                  child: Center(
                    child: FloatingActionButton.extended(
                      heroTag: 'recentre',
                      backgroundColor: Colors.white,
                      foregroundColor: HsColors.blue,
                      onPressed: _recenter,
                      icon: const Icon(Icons.navigation),
                      label: const Text('Re-centre', style: TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
              if (_banner != null)
                Positioned(
                  left: 24,
                  right: 24,
                  top: MediaQuery.of(context).padding.top + 170,
                  child: _reachedBanner(_banner!),
                ),
            ]),
    );
  }

  /// The way to the next stop and its alternatives, all on screen.
  void _fitRoute() {
    final pts = <LatLng>[
      for (final r in [if (_route != null) _route!, ..._alts])
        for (var i = 0; i < r.line.length; i += math.max(1, r.line.length ~/ 60)) LatLng(r.line[i][0], r.line[i][1]),
      if (_pos != null) LatLng(_pos!.latitude, _pos!.longitude),
    ];
    if (pts.length < 2) {
      _fitAll();
      return;
    }
    _camFit(pts, const EdgeInsets.fromLTRB(50, 220, 90, 200));
  }

  Widget _mapView(TripPlan plan) => _google ? _googleMap(plan) : _osmMap(plan);

  bool _night() {
    if (_theme == 'dark') return true;
    if (_theme == 'light') return false;
    final n = DateTime.now();
    final m = n.hour * 60 + n.minute;
    return m >= 18 * 60 + 30 || m < 6 * 60; // like Google Maps: dark after sunset
  }

  /// Layers button: map or satellite, and light / dark / automatic.
  Future<void> _mapLook() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) {
          void pick(VoidCallback f) {
            setState(f);
            set(() {});
          }

          Widget choice(String label, IconData icon, bool on, VoidCallback tap) => Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: tap,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: on ? HsColors.blue : const Color(0xFFDADCE0), width: on ? 2 : 1),
                        color: on ? HsColors.cardHigh : null,
                      ),
                      child: Column(children: [
                        Icon(icon, color: on ? HsColors.blue : HsColors.charcoal),
                        const SizedBox(height: 6),
                        Text(label, style: TextStyle(fontWeight: FontWeight.w600, color: on ? HsColors.blue : HsColors.charcoal)),
                      ]),
                    ),
                  ),
                ),
              );
          void theme(String t) => pick(() {
                _theme = t;
                _gKey = '';
                try {
                  Preferences.instance.setString(Preferences.tripMapTheme, t);
                } catch (_) {}
              });
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Map type', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                Row(children: [
                  choice('Default', Icons.map_outlined, !_satellite, () => pick(() => _satellite = false)),
                  choice('Satellite', Icons.satellite_alt_outlined, _satellite, () => pick(() => _satellite = true)),
                ]),
                const SizedBox(height: 18),
                const Text('Colour scheme', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                Row(children: [
                  choice('Automatic', Icons.brightness_auto_outlined, _theme == 'auto', () => theme('auto')),
                  choice('Light', Icons.light_mode_outlined, _theme == 'light', () => theme('light')),
                  choice('Dark', Icons.dark_mode_outlined, _theme == 'dark', () => theme('dark')),
                ]),
              ]),
            ),
          );
        },
      ),
    );
  }

  /// Top / bottom map padding: following, the camera centre (where the arrow is) sits low on the screen.
  (double, double) _gPad() {
    final bottom = 120 + MediaQuery.of(context).padding.bottom;
    final top = _follow && _headingUp ? _screenH * 0.5 : 170.0;
    return (top, bottom);
  }

  String _gKey = '';
  Set<gm.Polyline> _gLines = const {};
  Set<gm.Marker> _gMarks = const {};

  void _pickAlternative(int k) {
    if (_route == null || k >= _alts.length) return;
    setState(() {
      final pick = _alts[k];
      _use(pick, [_route!, for (var j = 0; j < _alts.length; j++) if (j != k) _alts[j]]);
    });
    _voice.say('Route changed.');
  }

  Widget _googleMap(TripPlan plan) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final night = _night();
    final stops = plan.stops.where((s) => s.hasLocation).toList();
    final next = _remaining().firstOrNull;
    void redraw() {
      if (mounted) setState(() => _gKey = '');
    }

    final key = [
      identityHashCode(_route), _userAt, identityHashCode(_glideTo), identityHashCode(_alts), identityHashCode(_pumps), identityHashCode(_detour),
      _track.length, night, _follow, for (final s in stops) _status(s), next?.idx,
    ].join('|');
    if (key != _gKey) {
      _gKey = key;
      int px(double w) => w.round(); // screen points: the map scales them for the screen itself
      final r = _route;
      final mainColor = night ? const Color(0xFF6E8BFF) : const Color(0xFF4433EE);
      final mainEdge = night ? const Color(0xFF2B3FA8) : const Color(0xFF2A1DB0);
      final altColor = night ? const Color(0xFF5B7896) : const Color(0xFFA9C2E8);
      gm.LatLng ll(List<double> p) => gm.LatLng(p[0], p[1]);
      _gLines = {
        if (_track.length > 1)
          gm.Polyline(
            polylineId: const gm.PolylineId('track'),
            points: [for (final p in _track) ll(p)],
            color: const Color(0x99607D8B),
            width: px(4),
            zIndex: 1,
          ),
        for (var k = 0; k < _alts.length; k++)
          if (_alts[k].line.length > 1)
            gm.Polyline(
              polylineId: gm.PolylineId('alt$k'),
              points: [for (final p in _alts[k].line) ll(p)],
              color: altColor,
              width: px(6),
              zIndex: 2,
              jointType: gm.JointType.round,
              startCap: gm.Cap.roundCap,
              endCap: gm.Cap.roundCap,
              consumeTapEvents: true,
              onTap: () => _pickAlternative(k),
            ),
        if (r != null && r.line.length > 1) ...[
          gm.Polyline(
            polylineId: const gm.PolylineId('edge'),
            points: [for (final p in r.line.skip(math.max(0, _userAt - 1))) ll(p)],
            color: mainEdge,
            width: px(9),
            zIndex: 3,
            jointType: gm.JointType.round,
            startCap: gm.Cap.roundCap,
            endCap: gm.Cap.roundCap,
          ),
          gm.Polyline(
            polylineId: const gm.PolylineId('route'),
            points: [for (final p in r.line.skip(math.max(0, _userAt - 1))) ll(p)],
            color: mainColor,
            width: px(6),
            zIndex: 4,
            jointType: gm.JointType.round,
            startCap: gm.Cap.roundCap,
            endCap: gm.Cap.roundCap,
          ),
          // not on the road yet (inside a building, a car park): dots to where the route starts, like Google
          if (_glideTo != null &&
              Geolocator.distanceBetween(_glideTo!.latitude, _glideTo!.longitude, r.line[math.min(_userAt, r.line.length - 1)][0],
                      r.line[math.min(_userAt, r.line.length - 1)][1]) >
                  12)
            gm.Polyline(
              polylineId: const gm.PolylineId('walk'),
              points: [gm.LatLng(_glideTo!.latitude, _glideTo!.longitude), ll(r.line[math.min(_userAt, r.line.length - 1)])],
              color: night ? const Color(0xFFBDC1C6) : const Color(0xFF5F6368),
              width: 4,
              zIndex: 6,
              patterns: [gm.PatternItem.dot, gm.PatternItem.gap(8)],
            ),
          for (var i = 0; i < r.traffic.length; i++)
            if (r.traffic[i][1] > _userAt && r.traffic[i][1] < r.line.length)
              gm.Polyline(
                polylineId: gm.PolylineId('traffic$i'),
                points: [
                  for (final p in r.line.sublist(math.max(r.traffic[i][0], math.max(0, _userAt - 1)), r.traffic[i][1] + 1))
                    ll(p),
                ],
                color: r.traffic[i][2] == 2 ? const Color(0xFFE53935) : const Color(0xFFF9A825),
                width: px(6),
                zIndex: 5,
                jointType: gm.JointType.round,
              ),
        ],
      };
      final marks = <gm.Marker>{};
      for (var k = 0; k < _alts.length; k++) {
        if (k >= _altLabelAt.length || _altLabelAt[k] == null || r == null) continue;
        final text = _altLabel(_alts[k]);
        final icon = NavIcons.get('label-$text-$night', dpr, (d) => NavIcons.label(d, text, dark: night), redraw);
        if (icon == null) continue;
        marks.add(gm.Marker(
          markerId: gm.MarkerId('altlabel$k'),
          position: gm.LatLng(_altLabelAt[k]!.latitude, _altLabelAt[k]!.longitude),
          icon: icon,
          anchor: const Offset(0.5, 0.5),
          consumeTapEvents: true,
          onTap: () => _pickAlternative(k),
        ));
      }
      // the next turn, labelled on the map like Google
      final nx = _nextStep();
      if (nx != null && nx.$1.type != 'arrive' && nx.$1.type != 'depart') {
        final t = _stepText(nx.$1);
        final parts = _roadParts(t);
        final text = parts == null ? t : '${parts.$1.isEmpty ? '' : '${parts.$1} '}${parts.$2}';
        final ic = _icon(nx.$1);
        final icon = NavIcons.get('callout-${ic.codePoint}-$text', dpr, (d) => NavIcons.callout(d, ic, text), redraw);
        if (icon != null) {
          marks.add(gm.Marker(
            markerId: const gm.MarkerId('turn'),
            position: gm.LatLng(nx.$1.lat, nx.$1.lon),
            icon: icon,
            anchor: const Offset(0.02, 0.9),
          ));
        }
      }
      for (final f in {..._pumps, if (_detour != null) _detour!}) {
        final going = identical(f, _detour);
        final icon = NavIcons.get('pump-$going', dpr, (d) => NavIcons.pump(d, going: going), redraw);
        if (icon == null) continue;
        marks.add(gm.Marker(
          markerId: gm.MarkerId('pump-${f.lat},${f.lon}'),
          position: gm.LatLng(f.lat, f.lon),
          icon: icon,
          anchor: const Offset(0.5, 0.5),
          consumeTapEvents: true,
          onTap: _showPumps,
        ));
      }
      for (final s in stops) {
        final n = plan.stops.indexOf(s) + 1;
        final st = _status(s);
        final isNext = identical(s, next);
        final color = isNext ? const Color(0xFF1F2A44) : (st == 'Pending' ? HsColors.blue : (stopColors[st] ?? HsColors.blue));
        final name = isNext ? s.name : null;
        final icon = NavIcons.get('stop-$n-$st-${name ?? ''}', dpr,
            (d) => NavIcons.stop(d, number: n, color: color, name: name), redraw);
        if (icon == null) continue;
        marks.add(gm.Marker(
          markerId: gm.MarkerId('stop${s.idx}'),
          position: gm.LatLng(s.lat!, s.lon!),
          icon: icon,
          anchor: Offset(0.5, isNext ? 0.25 : 0.5),
          consumeTapEvents: true,
          onTap: () => showStopSheet(context, s, n),
        ));
      }
      _gMarks = marks;
    }
    // the arrow: drawn over the map while following (never lags), a map marker otherwise
    final arrowIcon = NavIcons.get('arrow', dpr, NavIcons.arrow, redraw);
    final markers = {
      ..._gMarks,
      if (!_follow && _shown != null && arrowIcon != null)
        gm.Marker(
          markerId: const gm.MarkerId('me'),
          position: gm.LatLng(_shown!.latitude, _shown!.longitude),
          icon: arrowIcon,
          flat: true,
          rotation: _heading,
          anchor: const Offset(0.5, 0.5),
        ),
    };
    final (padTop, padBottom) = _gPad();
    final start = _pos != null
        ? gm.LatLng(_pos!.latitude, _pos!.longitude)
        : (stops.isNotEmpty ? gm.LatLng(stops.first.lat!, stops.first.lon!) : const gm.LatLng(10.55, 76.3));
    return Listener(
      onPointerDown: (e) => _downAt = e.position,
      onPointerMove: (e) {
        if (_follow && _downAt != null && (e.position - _downAt!).distance > 14) setState(() => _follow = false);
      },
      onPointerUp: (_) => _downAt = null,
      child: gm.GoogleMap(
        initialCameraPosition: gm.CameraPosition(target: start, zoom: 14),
        onMapCreated: (c) {
          _gmap = c;
          _mapReady = true;
          if (_pos != null) {
            _recenter();
          } else {
            _fitAll();
          }
        },
        style: night && !_satellite ? NavIcons.nightStyle : null,
        mapType: _satellite ? gm.MapType.hybrid : gm.MapType.normal,
        padding: EdgeInsets.only(top: padTop, bottom: padBottom),
        polylines: _gLines,
        markers: markers,
        circles: {
          if (_shown != null && !_moving && _pos != null && _pos!.accuracy > 8)
            gm.Circle(
              circleId: const gm.CircleId('accuracy'),
              center: gm.LatLng(_shown!.latitude, _shown!.longitude),
              radius: math.min(_pos!.accuracy, 150),
              fillColor: const Color(0x261783C1),
              strokeColor: const Color(0x661783C1),
              strokeWidth: 1,
            ),
        },
        onCameraMove: (c) => _bearing = c.bearing,
        buildingsEnabled: true,
        compassEnabled: false,
        mapToolbarEnabled: false,
        myLocationButtonEnabled: false,
        myLocationEnabled: false,
        zoomControlsEnabled: false,
        trafficEnabled: false,
        indoorViewEnabled: false,
      ),
    );
  }

  /// Where the Google camera keeps the arrow on screen while following.
  Widget _arrowOverlay() {
    final (padTop, padBottom) = _gPad();
    final y = padTop + (_screenH - padTop - padBottom) / 2;
    final turn = _headingUp ? _heading - _bearing : _heading;
    return Positioned(
      left: 0,
      right: 0,
      top: y - 38,
      child: IgnorePointer(
        child: Center(child: NavArrow(turn: turn, tilt: _headingUp ? 0.75 : 0, moving: _moving)),
      ),
    );
  }

  Widget _osmMap(TripPlan plan) {
    final stops = plan.stops.where((s) => s.hasLocation).toList();
    final next = _remaining().firstOrNull;
    final start = _pos != null
        ? LatLng(_pos!.latitude, _pos!.longitude)
        : (stops.isNotEmpty ? LatLng(stops.first.lat!, stops.first.lon!) : const LatLng(10.55, 76.3));
    return FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: start,
        initialZoom: 14,
        interactionOptions: const InteractionOptions(flags: InteractiveFlag.all),
        onMapReady: () {
          _mapReady = true;
          _fitAll();
        },
        onPositionChanged: (camera, hasGesture) {
          if (hasGesture && _follow) setState(() => _follow = false);
        },
      ),
      children: [
        hsTiles(satellite: _satellite),
        if (_track.length > 1)
          PolylineLayer(polylines: [
            Polyline(points: [for (final p in _track) LatLng(p[0], p[1])], strokeWidth: 4, color: const Color(0x99607D8B)),
          ]),
        if (_alts.isNotEmpty)
          PolylineLayer(polylines: [
            for (final a in _alts)
              if (a.line.length > 1)
                Polyline(
                  points: [for (final p in a.line) LatLng(p[0], p[1])],
                  strokeWidth: 7,
                  color: const Color(0xFFA9C2E8),
                  borderStrokeWidth: 2,
                  borderColor: const Color(0xFF7FA0D0),
                ),
          ]),
        if (_route != null && _route!.line.length > 1)
          PolylineLayer(polylines: [
            Polyline(
              points: [for (final p in _route!.line.skip(math.max(0, _userAt - 1))) LatLng(p[0], p[1])],
              strokeWidth: 9,
              color: const Color(0xFF3B5BFD),
              borderStrokeWidth: 2.5,
              borderColor: const Color(0xFF1A2DB5),
            ),
            // slow traffic orange, jams red, as Google reports them now
            for (final t in _route!.traffic)
              if (t[1] > _userAt && t[1] < _route!.line.length)
                Polyline(
                  points: [
                    for (final p in _route!.line.sublist(math.max(t[0], math.max(0, _userAt - 1)), t[1] + 1)) LatLng(p[0], p[1]),
                  ],
                  strokeWidth: 9,
                  color: t[2] == 2 ? const Color(0xFFD93025) : const Color(0xFFF29900),
                ),
          ]),
        if (_shown != null && !_moving && _pos != null && _pos!.accuracy > 8)
          CircleLayer(circles: [
            CircleMarker(
              point: _shown!,
              radius: math.min(_pos!.accuracy, 150),
              useRadiusInMeter: true,
              color: const Color(0x261783C1),
              borderColor: const Color(0x661783C1),
              borderStrokeWidth: 1,
            ),
          ]),
        MarkerLayer(markers: [
          // "3 min slower" / "Similar ETA" on each other way; tap it to take that way
          for (var k = 0; k < _alts.length; k++)
            if (_route != null && k < _altLabelAt.length && _altLabelAt[k] != null)
              Marker(
                point: _altLabelAt[k]!,
                rotate: true,
                width: 130,
                height: 56,
                child: GestureDetector(
                  onTap: () => setState(() {
                    final pick = _alts[k];
                    _use(pick, [_route!, for (var j = 0; j < _alts.length; j++) if (j != k) _alts[j]]);
                    _voice.say('Route changed.');
                  }),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 6, offset: Offset(0, 2))],
                      ),
                      child: Text(_altLabel(_alts[k]),
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: HsColors.charcoal)),
                    ),
                  ),
                ),
              ),
          for (final f in {..._pumps, if (_detour != null) _detour!})
            Marker(
              point: LatLng(f.lat, f.lon),
              width: 34,
              height: 34,
              rotate: true,
              child: GestureDetector(
                onTap: () => _showPumps(),
                child: Container(
                  decoration: BoxDecoration(
                    color: identical(f, _detour) ? const Color(0xFFE37400) : Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFFE37400), width: 2),
                    boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 4)],
                  ),
                  child: Icon(Icons.local_gas_station,
                      size: 20, color: identical(f, _detour) ? Colors.white : const Color(0xFFE37400)),
                ),
              ),
            ),
          for (final s in stops)
            Marker(
              point: LatLng(s.lat!, s.lon!),
              rotate: true,
              width: 150,
              height: identical(s, next) ? 74 : 40,
              alignment: Alignment.center,
              child: GestureDetector(
                onTap: () => showStopSheet(context, s, plan.stops.indexOf(s) + 1),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  SizedBox(
                    width: identical(s, next) ? 40 : 30,
                    height: identical(s, next) ? 40 : 30,
                    child: StopBadge(
                      number: plan.stops.indexOf(s) + 1,
                      status: _status(s),
                      highlight: identical(s, next),
                    ),
                  ),
                  if (identical(s, next))
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: HsColors.navy,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(s.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                    ),
                ]),
              ),
            ),
          if (_shown != null)
            Marker(
              point: _shown!,
              width: 56,
              height: 56,
              // drawn on the map (turns with it), then pointed along the heading
              rotate: false,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
                child: _moving ? _arrow() : _dot(),
              ),
            ),
        ]),
        hsAttribution,
      ],
    );
  }

  /// Moving: a navigation arrow pointing the way we're going.
  Widget _arrow() {
    return Transform.rotate(
      key: const ValueKey('arrow'),
      angle: _heading * math.pi / 180,
      child: Stack(alignment: Alignment.center, children: [
        Container(
          width: 46,
          height: 46,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0x331783C1),
          ),
        ),
        const Icon(Icons.navigation, color: Colors.white, size: 44),
        const Icon(Icons.navigation, color: HsColors.blue, size: 34),
      ]),
    );
  }

  /// Stopped: a blue dot with a faint cone showing which way the phone was last heading.
  Widget _dot() {
    return Transform.rotate(
      key: const ValueKey('dot'),
      angle: _heading * math.pi / 180,
      child: SizedBox(
        width: 56,
        height: 56,
        child: Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
        Positioned(
          top: 4,
          child: Container(
            width: 26,
            height: 22,
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.bottomCenter,
                radius: 1,
                colors: [Color(0x881783C1), Color(0x001783C1)],
              ),
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
          ),
        ),
        Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: HsColors.blue,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 5)],
          ),
        ),
      ]),
      ),
    );
  }

  String _altLabel(RoutePlan a) {
    final diff = a.duration - (_route?.duration ?? a.duration);
    final m = (diff.abs() / 60).round();
    if (m < 1) return 'Similar ETA';
    return diff > 0 ? '$m min slower' : '$m min faster';
  }

  Widget _topBar(TripPlan plan) {
    final step = _nextStep();
    final allDone = _remaining().isEmpty;
    final then = step == null ? null : _thenStep(step.$3);
    final text = step == null ? '' : _stepText(step.$1);
    final road = step == null || step.$1.type == 'arrive' ? null : _road(text);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Material(
          color: allDone ? HsColors.onDuty : _navGreen,
          borderRadius: BorderRadius.circular(20),
          elevation: 6,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
            child: allDone
                ? const Row(children: [
                    Icon(Icons.emoji_events, color: Colors.white, size: 40),
                    SizedBox(width: 14),
                    Expanded(
                      child: Text('All stops done — great work!',
                          style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700)),
                    ),
                  ])
                : step == null
                    ? Row(children: [
                        const Icon(Icons.navigation, color: Colors.white, size: 36),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            _gpsProblem ?? _routeError ?? (_routing || _route == null ? 'Finding the best route…' : 'Follow the blue line'),
                            style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ])
                    : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Icon(_icon(step.$1), color: Colors.white, size: 58),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(step.$2 < 15 ? 'Now' : _dist(step.$2),
                                style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w500, height: 1.15)),
                            const SizedBox(height: 4),
                            Text.rich(
                                road == null
                                    ? TextSpan(text: text)
                                    : _roadSpan(_roadParts(text)?.$1 ?? '', road, 30),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: road != null ? 30 : 24,
                                    fontWeight: FontWeight.w700,
                                    height: 1.15)),
                          ]),
                        ),
                      ]),
          ),
        ),
        if (then != null && !allDone)
          Container(
            margin: const EdgeInsets.only(left: 0, top: 0),
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 10),
            decoration: const BoxDecoration(
              color: _navGreenDark,
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(16)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Text('Then', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w500)),
              const SizedBox(width: 8),
              Icon(_icon(then), color: Colors.white, size: 30),
            ]),
          ),
      ]),
    );
  }

  Color _timeColor() {
    final r = _route;
    if (r == null || !r.live) return HsColors.onDuty;
    final d = r.delay;
    return d < 0.1 ? const Color(0xFF188038) : d < 0.3 ? const Color(0xFFE37400) : const Color(0xFFD93025);
  }

  Widget _bottomPanel(TripPlan plan) {
    final rem = _remaining();
    final next = rem.firstOrNull;
    final to = _toNext();
    final done = plan.stops.where((s) => _status(s) != 'Pending').length;
    final eta = to == null ? null : DateTime.now().add(Duration(seconds: to.$2.round()));
    void toggle([bool? open]) => setState(() => _panelOpen = open ?? !_panelOpen);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v < -150) toggle(true);
        if (v > 150) toggle(false);
      },
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [BoxShadow(color: Color(0x33000000), blurRadius: 14)],
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: AnimatedSize(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 5,
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(color: const Color(0xFFCBD5E1), borderRadius: BorderRadius.circular(3)),
                  ),
                ),
                Row(children: [
                  // exit, like Google's X
                  Material(
                    shape: const CircleBorder(side: BorderSide(color: Color(0xFF5F6368), width: 1.5)),
                    color: Colors.white,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => Navigator.of(context).pop(),
                      child: const SizedBox(width: 56, height: 56, child: Icon(Icons.close, size: 30, color: HsColors.charcoal)),
                    ),
                  ),
                  Expanded(
                    child: InkWell(
                      onTap: toggle,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: next == null
                            ? const Text('All stops done',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: HsColors.onDuty))
                            : Column(children: [
                                Text(to == null ? '–' : _mins(to.$2),
                                    style: TextStyle(fontSize: 30, fontWeight: FontWeight.w600, color: _timeColor(), height: 1.1)),
                                Text(
                                  to == null ? 'Finding the route…' : '${_dist(to.$1)}  •  ${DateFormat.jm().format(eta!)}',
                                  style: const TextStyle(color: Color(0xFF5F6368), fontSize: 17),
                                ),
                                Text(
                                    _detour != null
                                        ? '⛽ ${_detour!.name} · then stop ${plan.stops.indexOf(next) + 1}'
                                        : 'Stop ${plan.stops.indexOf(next) + 1} · ${next.name}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: HsColors.navy, fontSize: 13, fontWeight: FontWeight.w600)),
                              ]),
                      ),
                    ),
                  ),
                  Material(
                    shape: const CircleBorder(side: BorderSide(color: Color(0xFF5F6368), width: 1.5)),
                    color: Colors.white,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: toggle,
                      child: SizedBox(
                        width: 56,
                        height: 56,
                        child: Icon(_panelOpen ? Icons.keyboard_arrow_down : Icons.format_list_bulleted,
                            size: 28, color: HsColors.blue),
                      ),
                    ),
                  ),
                ]),
                if (_panelOpen) ...[
                  const SizedBox(height: 12),
                  if (next?.task != null && next!.task!.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(next.task!.trim(), maxLines: 2, overflow: TextOverflow.ellipsis),
                    ),
                  Row(children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: plan.stops.isEmpty ? 0 : done / plan.stops.length,
                          minHeight: 8,
                          color: HsColors.onDuty,
                          backgroundColor: HsColors.cardHigh,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text('$done of ${plan.stops.length} done', style: const TextStyle(fontWeight: FontWeight.w600)),
                  ]),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 64,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: plan.stops.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, i) {
                        final s = plan.stops[i];
                        final st = _status(s);
                        final isNext = identical(s, next);
                        return InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () {
                            showStopSheet(context, s, i + 1);
                            if (s.hasLocation && _mapReady) {
                              setState(() => _follow = false);
                              _camTo(LatLng(s.lat!, s.lon!), 16);
                            }
                          },
                          child: Container(
                            width: 132,
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            decoration: BoxDecoration(
                              color: isNext ? HsColors.cardHigh : HsColors.card,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: isNext ? HsColors.blue : Colors.transparent, width: 1.5),
                            ),
                            child: Row(children: [
                              SizedBox(width: 26, height: 26, child: StopBadge(number: i + 1, status: st)),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(s.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                                      Text(
                                        st == 'Pending'
                                            ? (s.planned ?? (isNext ? 'Next' : 'To visit'))
                                            : '${stopStatusLabel(st)}${s.arrived != null ? ' ${s.arrived}' : ''}',
                                        style: TextStyle(fontSize: 12, color: stopColors[st] ?? HsColors.textSecondary),
                                      ),
                                    ]),
                              ),
                            ]),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(children: [
                    if (next?.phone != null) ...[
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => callStop(context, next!),
                          icon: const Icon(Icons.call),
                          label: const Text('Call'),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    if (next != null) ...[
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _skipping ? null : () => _skip(next),
                          icon: const Icon(Icons.skip_next),
                          label: const Text('Skip stop'),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _route == null ? null : _showSteps,
                        icon: const Icon(Icons.format_list_numbered),
                        label: const Text('Directions'),
                      ),
                    ),
                  ]),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }

  void _showSteps() {
    final r = _route;
    if (r == null) return;
    final items = [
      for (var i = 0; i < r.steps.length; i++)
        if (_stepAt[i] > _userAt || r.steps[i].type == 'arrive') i,
    ];
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (ctx, scroll) => ListView.separated(
          controller: scroll,
          itemCount: items.length,
          separatorBuilder: (_, _) => const Divider(height: 1, indent: 64),
          itemBuilder: (ctx, k) {
            final s = r.steps[items[k]];
            final d = math.max(0.0, _cum[_stepAt[items[k]]] - (_cum.isEmpty ? 0 : _cum[_userAt]));
            return ListTile(
              leading: Icon(_icon(s), color: s.type == 'arrive' ? HsColors.onDuty : HsColors.navy, size: 30),
              title: Text(_stepText(s), style: TextStyle(fontWeight: s.type == 'arrive' ? FontWeight.w700 : FontWeight.w500)),
              trailing: Text(_dist(d), style: const TextStyle(color: HsColors.textSecondary)),
            );
          },
        ),
      ),
    );
  }

  Widget _reachedBanner(String text) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.6, end: 1),
      duration: const Duration(milliseconds: 450),
      curve: Curves.elasticOut,
      builder: (context, v, child) => Transform.scale(scale: v, child: child),
      child: Material(
        color: HsColors.onDuty,
        elevation: 8,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          child: Row(children: [
            const CircleAvatar(
              radius: 20,
              backgroundColor: Colors.white,
              child: Icon(Icons.check, color: HsColors.onDuty, size: 28),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(text,
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
      ),
    );
  }
}
