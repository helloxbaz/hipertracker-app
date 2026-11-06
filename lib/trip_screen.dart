import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'app_theme.dart';
import 'erp_service.dart';
import 'map_tiles.dart';
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
  static const _reachedWithin = 120.0; // metres: the ERP uses 150, the app says "Reached" a little before
  static const _offRoute = 80.0; // metres from the route before it is worked out again

  final _map = MapController();
  bool _mapReady = false;
  bool _follow = true;
  bool _satellite = false;

  TripPlan? _plan;
  List<List<double>> _track = const [];
  String? _loadError;

  Position? _pos;
  StreamSubscription<Position>? _gps;
  String? _gpsProblem;

  RoutePlan? _route;
  List<double> _cum = const []; // distance along the route to each line point
  List<int> _stepAt = const []; // line point of each step
  List<PlanStop> _routedStops = const [];
  int _userAt = 0;
  bool _routing = false;
  DateTime _routedAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _routeError;

  final Set<int> _reachedHere = {}; // stops the phone has just reached (before the ERP confirms)
  String? _banner;
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
    WakelockPlus.enable().catchError((_) {});
    _load();
    _startGps();
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => _load());
  }

  @override
  void dispose() {
    _gps?.cancel();
    _poll?.cancel();
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
      _gps = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.bestForNavigation, distanceFilter: 5),
      ).listen(_onPosition, onError: (_) {
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

    // reached the next stop?
    final rem = _remaining();
    if (rem.isNotEmpty && p.accuracy <= 60) {
      final next = rem.first;
      if (Geolocator.distanceBetween(p.latitude, p.longitude, next.lat!, next.lon!) <= _reachedWithin) {
        _reachedHere.add(next.idx);
        HapticFeedback.heavyImpact();
        _showBanner('Reached ${next.name}');
        final after = _remaining().firstOrNull;
        _voice.say(after == null
            ? 'You have reached ${next.name}. That was the last stop. All stops are done, great work!'
            : 'You have reached ${next.name}. Next stop, ${after.name}.');
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
      if (bestD > _offRoute && DateTime.now().difference(_routedAt).inSeconds > 20) {
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

    // zoom by speed, like a car navigator
    final kmh = speed * 3.6;
    final targetZoom = !_moving ? 17.2 : kmh < 15 ? 17.5 : kmh < 35 ? 16.8 : kmh < 60 ? 16.1 : 15.4;
    _zoom = _zoom + (targetZoom - _zoom) * 0.35;

    _glideFrom = _shown ?? here;
    _glideTo = here;
    _headingFrom = _heading;
    // turn the short way round
    var delta = heading - _headingFrom;
    if (delta > 180) delta -= 360;
    if (delta < -180) delta += 360;
    _headingTo = _headingFrom + delta;
    _glide.forward(from: 0);
  }

  void _onGlide() {
    final a = _glideFrom, b = _glideTo;
    if (a == null || b == null) return;
    final t = Curves.easeInOut.transform(_glide.value);
    _shown = LatLng(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t);
    _heading = _headingFrom + (_headingTo - _headingFrom) * t;
    if (_follow && _mapReady) {
      final rotation = _headingUp ? (_moving ? -_heading : _map.camera.rotation) : 0.0;
      _map.rotate(rotation);
      _map.move(_shown!, _zoom, offset: Offset(0, _headingUp ? _screenH * 0.2 : 0));
    }
    if (mounted) setState(() {});
  }

  void _recenter() {
    setState(() => _follow = true);
    final at = _shown ?? (_pos != null ? LatLng(_pos!.latitude, _pos!.longitude) : null);
    if (at != null && _mapReady) {
      _map.rotate(_headingUp && _moving ? -_heading : (_headingUp ? _map.camera.rotation : 0));
      _map.move(at, _zoom, offset: Offset(0, _headingUp ? _screenH * 0.2 : 0));
    }
  }

  Future<void> _reroute() async {
    if (_routing) return;
    final rem = _remaining();
    final from = _pos != null
        ? [_pos!.latitude, _pos!.longitude]
        : (_track.isNotEmpty ? _track.last : null);
    if (rem.isEmpty || from == null) {
      if (!mounted) return;
      setState(() {
        _route = null;
        _routedStops = const [];
      });
      return;
    }
    _routing = true;
    try {
      final stops = rem.take(24).toList();
      final r = await ErpService.route(from, [for (final s in stops) [s.lat!, s.lon!]]);
      final cum = <double>[0];
      for (var i = 1; i < r.line.length; i++) {
        cum.add(cum[i - 1] +
            Geolocator.distanceBetween(r.line[i - 1][0], r.line[i - 1][1], r.line[i][0], r.line[i][1]));
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
      if (!mounted) return;
      setState(() {
        _route = r;
        _cum = cum;
        _stepAt = at;
        _userAt = 0;
        _routedStops = stops;
        _routedAt = DateTime.now();
        _routeError = null;
        _spokenStep = -1;
        _spokenStage = 0;
      });
      if (!_greeted) {
        _greeted = true;
        final to = r.legs.isNotEmpty ? r.legs.first[0].toDouble() : r.distance.toDouble();
        _voice.say("Let's go. Your ${_plan!.done == 0 ? 'first' : 'next'} stop is ${stops.first.name}, "
            '${VoiceGuide.distance(to)} away.');
      } else if (_offRouteReroute) {
        _voice.say('Route updated.');
      }
      _offRouteReroute = false;
      if (_follow && _mapReady && _pos == null) _fitAll();
    } catch (e) {
      if (mounted) setState(() => _routeError = 'Route not available right now');
    } finally {
      _routing = false;
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
    if (pts.length > 1) {
      _map.fitCamera(CameraFit.coordinates(coordinates: pts, padding: const EdgeInsets.fromLTRB(40, 160, 40, 260)));
    } else if (pts.length == 1) {
      _map.move(pts.first, 15);
    }
  }

  // ---------------------------------------------------------------------------------------------
  // what to show

  /// The next instruction: [step, metres to it].
  (RouteStep, double)? _nextStep() {
    final r = _route;
    if (r == null || r.steps.isEmpty || _cum.isEmpty) return null;
    for (var i = 0; i < r.steps.length; i++) {
      final s = r.steps[i];
      if (s.type == 'depart') continue;
      if (_stepAt[i] > _userAt) return (s, math.max(0, _cum[_stepAt[i]] - _cum[_userAt]));
    }
    return null;
  }

  /// Announce the next turn: once well before it, once when it's coming up, and when it's here.
  void _speakDirections() {
    final r = _route;
    if (r == null || _pos == null || _cum.isEmpty) return;
    if (_remaining().isEmpty) {
      if (!_saidAllDone) {
        _saidAllDone = true;
        _voice.say('All stops are done. Great work!');
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
        _voice.say(s.type == 'arrive' ? text : '$text now.');
      } else if (d <= 250 && d > 40 && _spokenStage < 2) {
        _spokenStage = 2;
        _voice.say('In ${VoiceGuide.distance(d)}, $text.');
      } else if (d <= 1500 && d > 250 && _spokenStage < 1) {
        _spokenStage = 1;
        _voice.say('In ${VoiceGuide.distance(d)}, $text.');
      } else if (d > 1500 && _spokenStage < 1) {
        _spokenStage = 1;
        _voice.say('Continue for ${VoiceGuide.distance(d)}.');
      }
      return;
    }
  }

  String _spokenText(RouteStep s) {
    if (s.type == 'arrive') {
      final stop = s.leg < _routedStops.length ? _routedStops[s.leg].name : null;
      return stop == null ? 'you will arrive at your stop' : 'you will arrive at $stop';
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
      final stop = s.leg < _routedStops.length ? _routedStops[s.leg].name : null;
      return stop == null ? 'Arrive' : 'Arrive at $stop';
    }
    return s.text;
  }

  // ---------------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    _screenH = MediaQuery.of(context).size.height;
    final plan = _plan;
    return Scaffold(
      body: plan == null
          ? Center(
              child: _loadError == null
                  ? const CircularProgressIndicator()
                  : Padding(padding: const EdgeInsets.all(24), child: Text(_loadError!, textAlign: TextAlign.center)),
            )
          : Stack(children: [
              _mapView(plan),
              Positioned(left: 0, right: 0, top: 0, child: SafeArea(child: _topBar(plan))),
              Positioned(left: 0, right: 0, bottom: 0, child: _bottomPanel(plan)),
              Positioned(
                right: 14,
                bottom: 250,
                child: Column(children: [
                  FloatingActionButton.small(
                    heroTag: 'compass',
                    backgroundColor: Colors.white,
                    foregroundColor: HsColors.navy,
                    tooltip: _headingUp ? 'North up' : 'Direction of travel up',
                    onPressed: () {
                      setState(() => _headingUp = !_headingUp);
                      if (!_headingUp && _mapReady) _map.rotate(0);
                      _recenter();
                    },
                    child: Transform.rotate(
                      angle: (_mapReady ? _map.camera.rotation : 0) * math.pi / 180,
                      child: Icon(_headingUp ? Icons.explore : Icons.navigation_outlined),
                    ),
                  ),
                  const SizedBox(height: 10),
                  FloatingActionButton.small(
                    heroTag: 'voice',
                    backgroundColor: Colors.white,
                    foregroundColor: _voice.enabled ? HsColors.navy : HsColors.danger,
                    tooltip: _voice.enabled ? 'Mute voice' : 'Voice on',
                    onPressed: () {
                      setState(() => _voice.enabled = !_voice.enabled);
                      if (_voice.enabled) _voice.say('Voice directions on.');
                    },
                    child: Icon(_voice.enabled ? Icons.volume_up : Icons.volume_off),
                  ),
                  const SizedBox(height: 10),
                  FloatingActionButton.small(
                    heroTag: 'sat',
                    backgroundColor: Colors.white,
                    foregroundColor: HsColors.navy,
                    tooltip: _satellite ? 'Map' : 'Satellite',
                    onPressed: () => setState(() => _satellite = !_satellite),
                    child: Icon(_satellite ? Icons.map_outlined : Icons.satellite_alt),
                  ),
                  const SizedBox(height: 10),
                  FloatingActionButton.small(
                    heroTag: 'all',
                    backgroundColor: Colors.white,
                    foregroundColor: HsColors.navy,
                    tooltip: 'Whole trip',
                    onPressed: () {
                      setState(() => _follow = false);
                      _fitAll();
                    },
                    child: const Icon(Icons.zoom_out_map),
                  ),
                  const SizedBox(height: 10),
                  FloatingActionButton(
                    heroTag: 'me',
                    backgroundColor: _follow ? HsColors.blue : Colors.white,
                    foregroundColor: _follow ? Colors.white : HsColors.blue,
                    tooltip: 'Follow me',
                    onPressed: _recenter,
                    child: Icon(_follow ? Icons.navigation : Icons.my_location),
                  ),
                ]),
              ),
              if (_banner != null)
                Positioned(
                  left: 24,
                  right: 24,
                  top: MediaQuery.of(context).padding.top + 120,
                  child: _reachedBanner(_banner!),
                ),
            ]),
    );
  }

  Widget _mapView(TripPlan plan) {
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
        if (_route != null && _route!.line.length > 1)
          PolylineLayer(polylines: [
            Polyline(
              points: [for (final p in _route!.line.skip(math.max(0, _userAt - 1))) LatLng(p[0], p[1])],
              strokeWidth: 7,
              color: HsColors.blue,
              borderStrokeWidth: 3,
              borderColor: Colors.white,
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

  Widget _topBar(TripPlan plan) {
    final step = _nextStep();
    final allDone = _remaining().isEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Material(
          color: Colors.white,
          shape: const CircleBorder(),
          elevation: 3,
          child: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).pop()),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Material(
            color: allDone ? HsColors.onDuty : HsColors.navy,
            borderRadius: BorderRadius.circular(18),
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: allDone
                  ? const Row(children: [
                      Icon(Icons.emoji_events, color: Colors.white, size: 34),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text('All stops done — great work!',
                            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
                      ),
                    ])
                  : step == null
                      ? Text(
                          _gpsProblem ?? _routeError ?? (_routing || _route == null ? 'Finding the route…' : 'Follow the blue line'),
                          style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
                        )
                      : Row(children: [
                          Icon(_icon(step.$1), color: Colors.white, size: 40),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(_dist(step.$2),
                                  style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800)),
                              Text(_stepText(step.$1),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Color(0xFFD6E6F5), fontSize: 15)),
                            ]),
                          ),
                        ]),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _bottomPanel(TripPlan plan) {
    final rem = _remaining();
    final next = rem.firstOrNull;
    final to = _toNext();
    final done = plan.stops.where((s) => _status(s) != 'Pending').length;
    final eta = to == null ? null : DateTime.now().add(Duration(seconds: to.$2.round()));
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        boxShadow: [BoxShadow(color: Color(0x33000000), blurRadius: 12)],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (next != null) ...[
              Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Next stop ${plan.stops.indexOf(next) + 1}',
                        style: const TextStyle(color: HsColors.textSecondary, fontSize: 13)),
                    Text(next.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: HsColors.navy)),
                  ]),
                ),
                if (to != null)
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(_mins(to.$2), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: HsColors.onDuty)),
                    Text('${_dist(to.$1)} · ${DateFormat.jm().format(eta!)}',
                        style: const TextStyle(color: HsColors.textSecondary, fontSize: 13)),
                  ]),
              ]),
              if (next.task != null && next.task!.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(next.task!.trim(), maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              const SizedBox(height: 12),
            ],
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
              Text('$done of ${plan.stops.length} reached', style: const TextStyle(fontWeight: FontWeight.w600)),
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
                        _map.move(LatLng(s.lat!, s.lon!), 16);
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
                OutlinedButton.icon(
                  onPressed: () => callStop(context, next!),
                  icon: const Icon(Icons.call),
                  label: const Text('Call'),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _route == null ? null : _showSteps,
                  icon: const Icon(Icons.format_list_numbered),
                  label: const Text('All directions'),
                ),
              ),
            ]),
          ]),
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
