import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import 'app_theme.dart';
import 'erp_service.dart';
import 'stop_actions.dart';

/// The trip in progress: a full-screen map with the road route through the stops still to visit,
/// the next turn, distance and arrival time, and each stop ticking to "Reached" as the phone gets there.
class TripScreen extends StatefulWidget {
  const TripScreen({super.key, required this.planName});

  final String planName;

  @override
  State<TripScreen> createState() => _TripScreenState();
}

class _TripScreenState extends State<TripScreen> {
  static const _reachedWithin = 120.0; // metres: the ERP uses 150, the app says "Reached" a little before
  static const _offRoute = 80.0; // metres from the route before it is worked out again

  final _map = MapController();
  bool _mapReady = false;
  bool _follow = true;

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

  @override
  void initState() {
    super.initState();
    _load();
    _startGps();
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => _load());
  }

  @override
  void dispose() {
    _gps?.cancel();
    _poll?.cancel();
    _bannerTimer?.cancel();
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
      if (bestD > _offRoute && DateTime.now().difference(_routedAt).inSeconds > 20) _reroute();
    }
    if (first || _route == null) _reroute();

    if (_follow && _mapReady) {
      _map.move(LatLng(p.latitude, p.longitude), math.max(_map.camera.zoom, 15.5));
    }
    setState(() {});
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
      });
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
                    onPressed: () {
                      setState(() => _follow = true);
                      if (_pos != null) _map.move(LatLng(_pos!.latitude, _pos!.longitude), 16.5);
                    },
                    child: const Icon(Icons.my_location),
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
        interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
        onMapReady: () {
          _mapReady = true;
          _fitAll();
        },
        onPositionChanged: (camera, hasGesture) {
          if (hasGesture && _follow) setState(() => _follow = false);
        },
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'org.traccar.client',
        ),
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
        MarkerLayer(markers: [
          for (final s in stops)
            Marker(
              point: LatLng(s.lat!, s.lon!),
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
          if (_pos != null)
            Marker(
              point: LatLng(_pos!.latitude, _pos!.longitude),
              width: 44,
              height: 44,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 6)],
                ),
                child: Transform.rotate(
                  angle: (_pos!.heading.isFinite && _pos!.speed > 0.8 ? _pos!.heading : 0) * math.pi / 180,
                  child: const Icon(Icons.navigation, color: HsColors.blue, size: 30),
                ),
              ),
            ),
        ]),
        const RichAttributionWidget(attributions: [TextSourceAttribution('OpenStreetMap contributors')]),
      ],
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
                  onPressed: plan.directions() == null ? null : () => openDirections(context, plan),
                  icon: const Icon(Icons.record_voice_over),
                  label: const Text('Voice in Google Maps'),
                ),
              ),
            ]),
          ]),
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
