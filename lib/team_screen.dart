import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_theme.dart';
import 'erp_service.dart';
import 'map_tiles.dart';
import 'stop_actions.dart';

/// For managers: the team on a live map, each person's route for any day, everyone's trips, alerts and
/// the leave / expense requests waiting for approval — what the HiperTracker pages show in the ERP.
class TeamScreen extends StatelessWidget {
  const TeamScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('My team'),
          bottom: const TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [
            Tab(icon: Icon(Icons.map_outlined), text: 'Live'),
            Tab(icon: Icon(Icons.route_outlined), text: 'Trips'),
            Tab(icon: Icon(Icons.notifications_active_outlined), text: 'Alerts'),
            Tab(icon: Icon(Icons.fact_check_outlined), text: 'Approvals'),
          ]),
        ),
        body: const TabBarView(children: [_LiveTab(), _TripsTab(), _AlertsTab(), _ApprovalsTab()]),
      ),
    );
  }
}

const _statusColor = {
  'online': HsColors.onDuty,
  'offline': Color(0xFF6B7785),
  'gps_off': HsColors.danger,
  'off_duty': Color(0xFFB0BAC5),
  'unknown': Color(0xFFB0BAC5),
};
const _statusLabel = {
  'online': 'Online',
  'offline': 'Offline',
  'gps_off': 'GPS off',
  'off_duty': 'Off duty',
  'unknown': 'No data',
};

double _d(dynamic v) => double.tryParse('$v') ?? 0;

String _ago(dynamic minutes) {
  final m = _d(minutes);
  if (minutes == null) return 'never';
  if (m < 1) return 'just now';
  if (m < 60) return '${m.round()} min ago';
  if (m < 60 * 24) return '${(m / 60).floor()} h ago';
  return '${(m / 1440).floor()} d ago';
}

String _initials(String s) {
  final p = s.trim().split(RegExp(r'\s+')).where((x) => x.isNotEmpty).toList();
  if (p.isEmpty) return '?';
  return (p.first[0] + (p.length > 1 ? p.last[0] : '')).toUpperCase();
}

Widget _error(Object? e, VoidCallback retry) => Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('$e', textAlign: TextAlign.center),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: retry, child: const Text('Try again')),
        ]),
      ),
    );

// ------------------------------------------------------------------------------------------------
// Live
// ------------------------------------------------------------------------------------------------

class _LiveTab extends StatefulWidget {
  const _LiveTab();

  @override
  State<_LiveTab> createState() => _LiveTabState();
}

class _LiveTabState extends State<_LiveTab> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>>? _devices;
  Object? _err;
  Timer? _timer;
  final _map = MapController();
  bool _fitted = false;
  String _filter = 'all';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await ErpService.teamLive();
      final list = [for (final d in (r['devices'] as List? ?? const [])) if (d is Map<String, dynamic>) d];
      if (mounted) {
        setState(() {
          _devices = list;
          _err = null;
        });
      }
      if (!_fitted) _fit();
    } catch (e) {
      if (mounted) setState(() => _err = e);
    }
  }

  void _fit() {
    final pts = [
      for (final d in _devices ?? const <Map<String, dynamic>>[])
        if (d['lat'] != null && d['lon'] != null) LatLng(_d(d['lat']), _d(d['lon'])),
    ];
    if (pts.isEmpty) return;
    _fitted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        if (pts.length == 1) {
          _map.move(pts.first, 14);
        } else {
          _map.fitCamera(CameraFit.coordinates(coordinates: pts, padding: const EdgeInsets.all(40), maxZoom: 15));
        }
      } catch (_) {}
    });
  }

  void _open(Map<String, dynamic> d) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PersonDayScreen(device: '${d['record']}', name: '${d['employee_name'] ?? d['label'] ?? ''}', phone: d['phone']),
    ));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final all = _devices;
    if (all == null) {
      return _err != null ? _error(_err, _load) : const Center(child: CircularProgressIndicator());
    }
    int n(String s) => all.where((d) => d['status'] == s).length;
    final list = _filter == 'all' ? all : all.where((d) => d['status'] == _filter).toList();
    final h = MediaQuery.of(context).size.height;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: EdgeInsets.zero, children: [
        SizedBox(
          height: h * 0.38,
          child: FlutterMap(
            mapController: _map,
            options: const MapOptions(initialCenter: LatLng(10.55, 76.3), initialZoom: 8),
            children: [
              hsTiles(),
              // no GPS: a ring of how far off it may be (Wi-Fi / mobile tower)
              CircleLayer(circles: [
                for (final d in list)
                  if (d['approx'] != null && d['lat'] != null && d['lon'] != null)
                    CircleMarker(
                      point: LatLng(_d(d['lat']), _d(d['lon'])),
                      radius: _d(d['accuracy']),
                      useRadiusInMeter: true,
                      color: const Color(0x22B26A00),
                      borderColor: HsColors.warning,
                      borderStrokeWidth: 1.5,
                    ),
              ]),
              MarkerLayer(markers: [
                for (final d in list)
                  if (d['lat'] != null && d['lon'] != null)
                    Marker(
                      point: LatLng(_d(d['lat']), _d(d['lon'])),
                      width: 40,
                      height: 40,
                      child: GestureDetector(
                        onTap: () => _open(d),
                        child: Container(
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: _statusColor[d['status']] ?? HsColors.textSecondary,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2.5),
                            boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 4)],
                          ),
                          child: Text(_initials('${d['employee_name'] ?? d['label'] ?? ''}'),
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13)),
                        ),
                      ),
                    ),
              ]),
            ],
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Row(children: [
            for (final f in [
              ('all', 'All ${all.length}'),
              ('online', 'Online ${n('online')}'),
              ('gps_off', 'GPS off ${n('gps_off')}'),
              ('offline', 'Offline ${n('offline')}'),
              ('off_duty', 'Off duty ${n('off_duty')}'),
            ])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(f.$2),
                  selected: _filter == f.$1,
                  onSelected: (_) => setState(() => _filter = f.$1),
                ),
              ),
          ]),
        ),
        for (final d in list)
          ListTile(
            onTap: () => _open(d),
            leading: CircleAvatar(
              backgroundColor: _statusColor[d['status']] ?? HsColors.textSecondary,
              foregroundColor: Colors.white,
              child: Text(_initials('${d['employee_name'] ?? d['label'] ?? ''}'), style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
            title: Text('${d['employee_name'] ?? d['label'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text([
              _statusLabel[d['status']] ?? '${d['status']}',
              _ago(d['age_minutes']),
              if (d['place'] is Map) 'at ${d['place']['name']}',
              if (d['approx'] != null) 'approx. (${d['approx']})',
              if (_d(d['speed']) > 3) '${_d(d['speed']).round()} km/h',
              if (d['battery'] != null) '${_d(d['battery']).round()}% battery',
            ].join(' · ')),
            trailing: const Icon(Icons.chevron_right),
          ),
        const SizedBox(height: 24),
      ]),
    );
  }
}

// ------------------------------------------------------------------------------------------------
// One person's day
// ------------------------------------------------------------------------------------------------

class PersonDayScreen extends StatefulWidget {
  const PersonDayScreen({super.key, required this.device, required this.name, this.phone});

  final String device;
  final String name;
  final dynamic phone;

  @override
  State<PersonDayScreen> createState() => _PersonDayScreenState();
}

class _PersonDayScreenState extends State<PersonDayScreen> {
  DateTime _day = DateTime.now();
  Map<String, dynamic>? _data;
  List _trips = const [];
  Object? _err;
  bool _loading = false;
  final _map = MapController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      final r = await ErpService.teamDay(widget.device, _day);
      final trips = await ErpService.teamTrips(_day);
      if (!mounted) return;
      setState(() {
        _data = r;
        _trips = trips.where((t) => t is Map && t['device'] == widget.device).toList();
      });
      final pts = _points();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          if (pts.length > 1) {
            _map.fitCamera(CameraFit.coordinates(coordinates: pts, padding: const EdgeInsets.all(30), maxZoom: 16));
          } else if (pts.length == 1) {
            _map.move(pts.first, 15);
          }
        } catch (_) {}
      });
    } catch (e) {
      if (mounted) setState(() => _err = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<LatLng> _points() => [
        for (final p in (_data?['points'] as List? ?? const []))
          if (p is List && p.length >= 2) LatLng(_d(p[0]), _d(p[1])),
      ];

  int _mins(String hhmm) {
    final p = hhmm.split(':');
    return p.length < 2 ? 0 : (int.tryParse(p[0]) ?? 0) * 60 + (int.tryParse(p[1]) ?? 0);
  }

  /// The route in pieces, and the gaps where the phone sent nothing for a while.
  (List<List<LatLng>>, List<List<LatLng>>) _parts() {
    final raw = (_data?['points'] as List? ?? const []).whereType<List>().where((p) => p.length >= 3).toList();
    final parts = <List<LatLng>>[[]];
    final gaps = <List<LatLng>>[];
    const dist = Distance();
    for (var k = 0; k < raw.length; k++) {
      final p = LatLng(_d(raw[k][0]), _d(raw[k][1]));
      if (k > 0) {
        final q = LatLng(_d(raw[k - 1][0]), _d(raw[k - 1][1]));
        final gapMin = _mins('${raw[k][2]}') - _mins('${raw[k - 1][2]}');
        if (gapMin > 10 && dist.as(LengthUnit.Meter, q, p) > 1000) {
          gaps.add([q, p]);
          parts.add([]);
        }
      }
      parts.last.add(p);
    }
    return (parts, gaps);
  }

  String _dayLabel() {
    final now = DateTime.now();
    final d0 = DateTime(_day.year, _day.month, _day.day);
    final diff = DateTime(now.year, now.month, now.day).difference(d0).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${_day.day} ${m[_day.month - 1]} ${_day.year}';
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final (parts, gaps) = _parts();
    final stops = (d?['stops'] as List? ?? const []).whereType<Map>().toList();
    final checkins = (d?['checkins'] as List? ?? const []).whereType<Map>().toList();
    final speeding = (d?['speeding'] as List? ?? const []).whereType<Map>().toList();
    final events = (d?['events'] as List? ?? const []).whereType<Map>().where((e) => '${e['event']}'.startsWith('GPS')).toList();
    final isToday = DateUtils.isSameDay(_day, DateTime.now());
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name),
        actions: [
          if (widget.phone != null && '${widget.phone}'.isNotEmpty)
            IconButton(
              tooltip: 'Call',
              icon: const Icon(Icons.call),
              onPressed: () => launchUrl(Uri.parse('tel:${widget.phone}')),
            ),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(children: [
            IconButton(
              icon: const Icon(Icons.chevron_left),
              onPressed: () {
                _day = _day.subtract(const Duration(days: 1));
                _load();
              },
            ),
            Expanded(
              child: TextButton(
                onPressed: () async {
                  final p = await showDatePicker(
                      context: context, initialDate: _day, firstDate: DateTime(2024), lastDate: DateTime.now());
                  if (p != null) {
                    _day = p;
                    _load();
                  }
                },
                child: Text(_dayLabel(), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              onPressed: isToday
                  ? null
                  : () {
                      _day = _day.add(const Duration(days: 1));
                      _load();
                    },
            ),
          ]),
        ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: _err != null
              ? _error(_err, _load)
              : d == null
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(padding: EdgeInsets.zero, children: [
                      SizedBox(
                        height: MediaQuery.of(context).size.height * 0.36,
                        child: FlutterMap(
                          mapController: _map,
                          options: const MapOptions(initialCenter: LatLng(10.55, 76.3), initialZoom: 8),
                          children: [
                            hsTiles(),
                            PolylineLayer(polylines: [
                              for (final g in gaps)
                                Polyline(
                                    points: g, strokeWidth: 2, color: const Color(0xFF9CA3AF), pattern: StrokePattern.dotted()),
                              for (final p in parts)
                                if (p.length > 1)
                                  Polyline(
                                      points: p,
                                      strokeWidth: 5,
                                      color: HsColors.blue,
                                      borderStrokeWidth: 1.5,
                                      borderColor: Colors.white),
                            ]),
                            MarkerLayer(markers: [
                              for (final s in stops)
                                Marker(
                                  point: LatLng(_d(s['lat']), _d(s['lon'])),
                                  width: 26,
                                  height: 26,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFF59E0B),
                                      shape: BoxShape.circle,
                                      border: Border.all(color: Colors.white, width: 2),
                                    ),
                                    child: const Icon(Icons.pause, size: 14, color: Colors.white),
                                  ),
                                ),
                              for (final c in checkins)
                                if (c['lat'] != null && c['lon'] != null)
                                  Marker(
                                    point: LatLng(_d(c['lat']), _d(c['lon'])),
                                    width: 28,
                                    height: 28,
                                    child: Icon(Icons.location_on,
                                        size: 28, color: c['log_type'] == 'IN' ? HsColors.onDuty : HsColors.checkOut),
                                  ),
                              if (_points().isNotEmpty)
                                Marker(
                                  point: _points().last,
                                  width: 22,
                                  height: 22,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: HsColors.danger,
                                      shape: BoxShape.circle,
                                      border: Border.all(color: Colors.white, width: 3),
                                    ),
                                  ),
                                ),
                            ]),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(14),
                        child: HsPanel(
                          child: Row(children: [
                            _stat('${_d(d['distance_km']).toStringAsFixed(1)} km', 'Distance'),
                            _stat(hsDuration(_d(d['moving_minutes']).round()), 'Moving'),
                            _stat(hsDuration(_d(d['stopped_minutes']).round()), 'Stopped'),
                          ]),
                        ),
                      ),
                      if (gaps.isNotEmpty)
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                          child: Text('Grey dots: the phone sent no location there (switched off, GPS off, app closed or no network).',
                              style: TextStyle(color: HsColors.textSecondary, fontSize: 12)),
                        ),
                      if (checkins.isNotEmpty) _section('Check in / out', [
                        for (final c in checkins)
                          ListTile(
                            dense: true,
                            leading: Icon(c['log_type'] == 'IN' ? Icons.login : Icons.logout,
                                color: c['log_type'] == 'IN' ? HsColors.onDuty : HsColors.checkOut),
                            title: Text(c['log_type'] == 'IN' ? 'Checked in' : 'Checked out'),
                            trailing: Text('${c['time']}'.length >= 16 ? '${c['time']}'.substring(11, 16) : '${c['time']}'),
                          ),
                      ]),
                      if (_trips.isNotEmpty) _section('Trips', [
                        for (final t in _trips)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.route, color: HsColors.navy),
                            title: Text('${t['title']}'),
                            subtitle: Text('${t['status']} · ${t['progress'] ?? ''} · '
                                'planned ${_d(t['planned_km']).toStringAsFixed(1)} km · travelled ${_d(t['actual_km']).toStringAsFixed(1)} km'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => TeamTripScreen(plan: '${t['name']}', title: '${t['title']}', who: widget.name))),
                          ),
                      ]),
                      if (stops.isNotEmpty) _section('Stops', [
                        for (final s in stops)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.pause_circle_outline, color: Color(0xFFF59E0B)),
                            title: Text('${s['start']} – ${s['ongoing'] == true ? 'now' : s['end']}'),
                            subtitle: Text(hsDuration(_d(s['minutes']).round())),
                            trailing: IconButton(
                              tooltip: 'Open in Maps',
                              icon: const Icon(Icons.map_outlined),
                              onPressed: () => launchUrl(Uri.parse('https://www.google.com/maps?q=${s['lat']},${s['lon']}'),
                                  mode: LaunchMode.externalApplication),
                            ),
                          ),
                      ]),
                      if (speeding.isNotEmpty) _section('Over the speed limit', [
                        for (final s in speeding)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.speed, color: HsColors.danger),
                            title: Text('${s['max_speed']} km/h'),
                            subtitle: Text('${s['start']} – ${s['end']}'),
                          ),
                      ]),
                      if (events.isNotEmpty) _section('GPS', [
                        for (final e in events)
                          ListTile(
                            dense: true,
                            leading: Icon(e['event'] == 'GPS On' ? Icons.gps_fixed : Icons.gps_off,
                                color: e['event'] == 'GPS On' ? HsColors.onDuty : HsColors.danger),
                            title: Text('${e['event']}'),
                            trailing: Text('${e['time']}'.length >= 16 ? '${e['time']}'.substring(11, 16) : ''),
                          ),
                      ]),
                      if (parts.every((p) => p.length < 2) && stops.isEmpty && checkins.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(child: Text('Nothing recorded this day.')),
                        ),
                      const SizedBox(height: 24),
                    ]),
        ),
      ]),
    );
  }

  Widget _stat(String v, String l) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(v, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          Text(l, style: const TextStyle(color: HsColors.textSecondary, fontSize: 12)),
        ]),
      );
}

Widget _section(String title, List<Widget> children) => Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 6, 2, 4),
          child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: HsColors.navy)),
        ),
        HsPanel(padding: EdgeInsets.zero, child: Column(children: children)),
      ]),
    );

// ------------------------------------------------------------------------------------------------
// Trips
// ------------------------------------------------------------------------------------------------

class _TripsTab extends StatefulWidget {
  const _TripsTab();

  @override
  State<_TripsTab> createState() => _TripsTabState();
}

class _TripsTabState extends State<_TripsTab> with AutomaticKeepAliveClientMixin {
  DateTime _day = DateTime.now();
  List? _trips;
  Object? _err;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final t = await ErpService.teamTrips(_day);
      if (mounted) {
        setState(() {
          _trips = t;
          _err = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _err = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = _trips;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(12), children: [
        Row(children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () {
              _day = _day.subtract(const Duration(days: 1));
              setState(() => _trips = null);
              _load();
            },
          ),
          Expanded(
            child: Center(
              child: Text(DateUtils.isSameDay(_day, DateTime.now()) ? 'Today' : '${_day.day}-${_day.month}-${_day.year}',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: DateUtils.isSameDay(_day, DateTime.now())
                ? null
                : () {
                    _day = _day.add(const Duration(days: 1));
                    setState(() => _trips = null);
                    _load();
                  },
          ),
        ]),
        if (_err != null)
          _error(_err, _load)
        else if (t == null)
          const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
        else if (t.isEmpty)
          const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('No trips planned this day.')))
        else
          for (final x in t.whereType<Map>())
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                tileColor: HsColors.card,
                leading: const Icon(Icons.route, color: HsColors.navy),
                title: Text('${x['employee_name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('${x['title']}\n${x['status']} · ${x['progress'] ?? ''} · '
                    'planned ${_d(x['planned_km']).toStringAsFixed(1)} km · travelled ${_d(x['actual_km']).toStringAsFixed(1)} km'),
                isThreeLine: true,
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) =>
                        TeamTripScreen(plan: '${x['name']}', title: '${x['title']}', who: '${x['employee_name']}'))),
              ),
            ),
      ]),
    );
  }
}

/// A trip as the manager sees it: planned stops, the route taken (gaps shown apart) and when each stop was reached.
class TeamTripScreen extends StatefulWidget {
  const TeamTripScreen({super.key, required this.plan, required this.title, required this.who});

  final String plan;
  final String title;
  final String who;

  @override
  State<TeamTripScreen> createState() => _TeamTripScreenState();
}

class _TeamTripScreenState extends State<TeamTripScreen> {
  Map<String, dynamic>? _trip;
  Object? _err;
  final _map = MapController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await ErpService.teamTrip(widget.plan);
      if (!mounted) return;
      setState(() => _trip = r);
      final all = [
        for (final p in (r['points'] as List? ?? const [])) if (p is List) LatLng(_d(p[0]), _d(p[1])),
        for (final s in (r['stops'] as List? ?? const [])) if (s is Map) LatLng(_d(s['lat']), _d(s['lon'])),
      ];
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          if (all.length > 1) {
            _map.fitCamera(CameraFit.coordinates(coordinates: all, padding: const EdgeInsets.all(36), maxZoom: 16));
          }
        } catch (_) {}
      });
    } catch (e) {
      if (mounted) setState(() => _err = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _trip;
    final raw = (d?['points'] as List? ?? const []).whereType<List>().toList();
    final parts = <List<LatLng>>[[]];
    final gaps = <List<LatLng>>[];
    for (var k = 0; k < raw.length; k++) {
      final p = LatLng(_d(raw[k][0]), _d(raw[k][1]));
      if (k > 0 && raw[k].length > 3 && raw[k][3] == 1) {
        gaps.add([LatLng(_d(raw[k - 1][0]), _d(raw[k - 1][1])), p]);
        parts.add([]);
      }
      parts.last.add(p);
    }
    final stops = (d?['stops'] as List? ?? const []).whereType<Map>().toList();
    return Scaffold(
      appBar: AppBar(title: Text(widget.who)),
      body: _err != null
          ? _error(_err, _load)
          : d == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(padding: EdgeInsets.zero, children: [
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.38,
                    child: FlutterMap(
                      mapController: _map,
                      options: const MapOptions(initialCenter: LatLng(10.55, 76.3), initialZoom: 8),
                      children: [
                        hsTiles(),
                        PolylineLayer(polylines: [
                          if (stops.length > 1)
                            Polyline(
                              points: [for (final s in stops) LatLng(_d(s['lat']), _d(s['lon']))],
                              strokeWidth: 2.5,
                              color: HsColors.navy,
                              pattern: StrokePattern.dashed(segments: const [10, 8]),
                            ),
                          for (final g in gaps)
                            Polyline(points: g, strokeWidth: 2, color: const Color(0xFF9CA3AF), pattern: StrokePattern.dotted()),
                          for (final p in parts)
                            if (p.length > 1)
                              Polyline(
                                  points: p, strokeWidth: 5, color: HsColors.blue, borderStrokeWidth: 1.5, borderColor: Colors.white),
                        ]),
                        MarkerLayer(markers: [
                          for (var i = 0; i < stops.length; i++)
                            Marker(
                              point: LatLng(_d(stops[i]['lat']), _d(stops[i]['lon'])),
                              width: 28,
                              height: 28,
                              child: StopBadge(number: i + 1, status: '${stops[i]['status']}'),
                            ),
                          if (d['last'] is Map)
                            Marker(
                              point: LatLng(_d(d['last']['lat']), _d(d['last']['lon'])),
                              width: 22,
                              height: 22,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: HsColors.danger,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white, width: 3),
                                ),
                              ),
                            ),
                        ]),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: HsPanel(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(widget.title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                        const SizedBox(height: 6),
                        Text('${d['status']} · ${d['progress'] ?? ''} · planned ${_d(d['planned_km']).toStringAsFixed(1)} km · '
                            'travelled ${_d(d['actual_km']).toStringAsFixed(1)} km'),
                        if ((d['gaps'] as List? ?? const []).isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              'No location from the phone: ${(d['gaps'] as List).map((g) => '${g['from']}–${g['to']}').join(', ')}',
                              style: const TextStyle(color: HsColors.warning, fontSize: 13),
                            ),
                          ),
                      ]),
                    ),
                  ),
                  _section('Stops', [
                    for (var i = 0; i < stops.length; i++)
                      ListTile(
                        leading: SizedBox(width: 28, height: 28, child: StopBadge(number: i + 1, status: '${stops[i]['status']}')),
                        title: Text('${stops[i]['name']}'),
                        subtitle: Text([
                          stopStatusLabel('${stops[i]['status']}'),
                          if (stops[i]['planned'] != null) 'planned ${stops[i]['planned']}',
                          if (stops[i]['arrived'] != null) 'reached ${stops[i]['arrived']}',
                          if (stops[i]['left'] != null) 'left ${stops[i]['left']}',
                          if (_d(stops[i]['late']) > 5) '${_d(stops[i]['late']).round()} min late',
                        ].join(' · ')),
                      ),
                  ]),
                  const SizedBox(height: 24),
                ]),
    );
  }
}

// ------------------------------------------------------------------------------------------------
// Alerts
// ------------------------------------------------------------------------------------------------

class _AlertsTab extends StatefulWidget {
  const _AlertsTab();

  @override
  State<_AlertsTab> createState() => _AlertsTabState();
}

class _AlertsTabState extends State<_AlertsTab> with AutomaticKeepAliveClientMixin {
  Map<String, dynamic>? _data;
  Object? _err;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await ErpService.teamAlerts();
      if (mounted) {
        setState(() {
          _data = r;
          _err = null;
        });
      }
      unawaited(ErpService.teamAlertsRead().catchError((_) {}));
    } catch (e) {
      if (mounted) setState(() => _err = e);
    }
  }

  IconData _icon(String s) {
    final t = s.toLowerCase();
    if (t.contains('gps')) return Icons.gps_off;
    if (t.contains('speed')) return Icons.speed;
    if (t.contains('offline') || t.contains('no location') || t.contains('not reporting')) return Icons.signal_wifi_off;
    if (t.contains('enter') || t.contains('left') || t.contains('arriv')) return Icons.place_outlined;
    return Icons.notifications_outlined;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final d = _data;
    if (d == null) return _err != null ? _error(_err, _load) : const Center(child: CircularProgressIndicator());
    final now = (d['now'] as List? ?? const []).whereType<Map>().toList();
    final alerts = (d['alerts'] as List? ?? const []).whereType<Map>().toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(12), children: [
        if (now.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: Text('Right now', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: HsColors.navy)),
          ),
          for (final n in now)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                tileColor: HsColors.dangerBg,
                leading: Icon(n['status'] == 'gps_off' ? Icons.gps_off : Icons.signal_wifi_off, color: HsColors.danger),
                title: Text('${n['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('${n['status'] == 'gps_off' ? 'GPS is off' : 'Not reporting'}'
                    '${n['since'] != null ? ' since ${'${n['since']}'.length >= 16 ? '${n['since']}'.substring(11, 16) : n['since']}' : ''}'
                    '${n['battery'] != null ? ' · ${_d(n['battery']).round()}% battery' : ''}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => PersonDayScreen(device: '${n['device']}', name: '${n['name']}'))),
              ),
            ),
          const SizedBox(height: 8),
        ],
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 4, 4, 8),
          child: Text('Last 3 days', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: HsColors.navy)),
        ),
        if (alerts.isEmpty)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('No alerts.')))
        else
          HsPanel(
            padding: EdgeInsets.zero,
            child: Column(children: [
              for (final a in alerts)
                ListTile(
                  leading: Icon(_icon('${a['subject']}'), color: a['read'] == 1 ? HsColors.textSecondary : HsColors.danger),
                  title: Text('${a['subject']}', style: TextStyle(fontWeight: a['read'] == 1 ? FontWeight.w400 : FontWeight.w700)),
                  subtitle: Text('${a['time']}'),
                  onTap: a['device'] == null
                      ? null
                      : () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => PersonDayScreen(device: '${a['device']}', name: '${a['subject']}'.split(' ').take(2).join(' ')))),
                ),
            ]),
          ),
      ]),
    );
  }
}

// ------------------------------------------------------------------------------------------------
// Approvals
// ------------------------------------------------------------------------------------------------

class _ApprovalsTab extends StatefulWidget {
  const _ApprovalsTab();

  @override
  State<_ApprovalsTab> createState() => _ApprovalsTabState();
}

class _ApprovalsTabState extends State<_ApprovalsTab> with AutomaticKeepAliveClientMixin {
  List? _items;
  Object? _err;
  final Set<String> _busy = {};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await ErpService.teamRequests();
      if (mounted) {
        setState(() {
          _items = r;
          _err = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _err = e);
    }
  }

  Future<void> _decide(Map x, bool approve) async {
    String? reason;
    if (!approve) {
      final ctl = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Reject?'),
          content: TextField(controller: ctl, decoration: const InputDecoration(labelText: 'Reason (optional)')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reject')),
          ],
        ),
      );
      if (ok != true) return;
      reason = ctl.text.trim();
    }
    setState(() => _busy.add('${x['name']}'));
    try {
      final r = await ErpService.teamDecide('${x['doctype']}', '${x['name']}', approve, reason: reason);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(r['note'] != null ? '${r['note']}' : '${x['who']}: ${approve ? 'approved' : 'rejected'}')));
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy.remove('${x['name']}'));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final items = _items;
    if (items == null) return _err != null ? _error(_err, _load) : const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(12), children: [
        if (items.isEmpty)
          const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('Nothing waiting for approval.'))),
        for (final x in items.whereType<Map>())
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: HsPanel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(x['doctype'] == 'Leave Application' ? Icons.event_busy : Icons.receipt_long, color: HsColors.navy),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('${x['who']}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  ),
                  Text('${x['created']}'.length >= 10 ? '${x['created']}'.substring(5, 10) : '',
                      style: const TextStyle(color: HsColors.textSecondary, fontSize: 12)),
                ]),
                const SizedBox(height: 6),
                if (x['doctype'] == 'Leave Application')
                  Text('${x['kind']} · ${x['from']}${x['to'] != x['from'] ? ' to ${x['to']}' : ''} · '
                      '${_d(x['days']) % 1 == 0 ? _d(x['days']).round() : _d(x['days'])} day${_d(x['days']) == 1 ? '' : 's'}'
                      '${x['half_day'] == 1 ? ' (half day)' : ''}')
                else ...[
                  Text('₹${_d(x['amount']).round()} · ${x['date']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  for (final i in (x['items'] as List? ?? const []).whereType<Map>())
                    Text('• ${i['type']}: ₹${_d(i['amount']).round()}${'${i['description']}'.isNotEmpty ? ' — ${i['description']}' : ''}',
                        style: const TextStyle(color: HsColors.textSecondary, fontSize: 13)),
                ],
                if ('${x['note']}'.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('“${x['note']}”', style: const TextStyle(fontStyle: FontStyle.italic)),
                  ),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy.contains('${x['name']}') ? null : () => _decide(x, false),
                      icon: const Icon(Icons.close),
                      label: const Text('Reject'),
                      style: OutlinedButton.styleFrom(foregroundColor: HsColors.danger),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy.contains('${x['name']}') ? null : () => _decide(x, true),
                      icon: const Icon(Icons.check),
                      label: const Text('Approve'),
                      style: FilledButton.styleFrom(backgroundColor: HsColors.onDuty),
                    ),
                  ),
                ]),
              ]),
            ),
          ),
      ]),
    );
  }
}

