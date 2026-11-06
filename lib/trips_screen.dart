import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import 'app_theme.dart';
import 'erp_service.dart';
import 'expenses_screen.dart';
import 'map_tiles.dart';
import 'plan_trip_screen.dart';
import 'stop_actions.dart';
import 'trip_screen.dart';

const _statusColors = {
  'Planned': HsColors.blue,
  'In Progress': Color(0xFFF59E0B),
  'Completed': HsColors.onDuty,
  'Cancelled': Color(0xFF9CA3AF),
};

String _dayLabel(String? date) {
  final d = date == null ? null : DateTime.tryParse(date);
  if (d == null) return '';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final diff = DateTime(d.year, d.month, d.day).difference(today).inDays;
  if (diff == 0) return 'Today';
  if (diff == -1) return 'Yesterday';
  if (diff == 1) return 'Tomorrow';
  return DateFormat('EEE, d MMM').format(d);
}

Widget _statusChip(String status) {
  final c = _statusColors[status] ?? HsColors.textSecondary;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)),
    child: Text(status, style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w700)),
  );
}

String _fuelText(TripPlan t) =>
    t.fuelLitres > 0 ? '${t.fuelLitres.toStringAsFixed(1)} L${t.fuelCost > 0 ? ' · ${hsMoney(t.fuelCost)}' : ''}' : '';

/// My trips: every trip plan of the worker (planned by the office or in the app), newest first.
class TripsScreen extends StatefulWidget {
  const TripsScreen({super.key});

  @override
  State<TripsScreen> createState() => _TripsScreenState();
}

class _TripsScreenState extends State<TripsScreen> {
  List<TripPlan>? _trips;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final t = await ErpService.myTrips();
      if (mounted) {
        setState(() {
          _trips = t;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final trips = _trips;
    return Scaffold(
      appBar: AppBar(title: const Text('My trips')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _open(const PlanTripScreen()),
        icon: const Icon(Icons.add_road),
        label: const Text('Plan a trip'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 96), children: [
          if (_error != null) ...[HsBanner(text: _error!, error: true), const SizedBox(height: 12)],
          if (trips == null && _error == null)
            const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
          if (trips != null && trips.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Text('No trips yet. Plan one with the button below.',
                  textAlign: TextAlign.center, style: TextStyle(color: HsColors.textSecondary)),
            ),
          for (final t in trips ?? const <TripPlan>[]) _card(t),
        ]),
      ),
    );
  }

  Widget _card(TripPlan t) {
    final line = [
      if (t.plannedKm > 0) hsKm(t.plannedKm),
      if (t.plannedMinutes > 0) hsDuration(t.plannedMinutes),
      if (_fuelText(t).isNotEmpty) _fuelText(t),
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: HsColors.card,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _open(TripDetailScreen(planName: t.name)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text(_dayLabel(t.date),
                        style: const TextStyle(color: HsColors.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 8),
                    _statusChip(t.status),
                  ]),
                  const SizedBox(height: 4),
                  Text(t.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: HsColors.navy)),
                  const SizedBox(height: 2),
                  Text('${t.progress ?? '${t.stops.length}'} stops${line.isEmpty ? '' : ' · $line'}',
                      style: const TextStyle(color: HsColors.textSecondary, fontSize: 13)),
                  if (t.actualKm > 0)
                    Text('Travelled ${hsKm(t.actualKm)}${t.started != null ? ' · ${t.started}' : ''}'
                        '${t.finished != null ? '–${t.finished}' : ''}',
                        style: const TextStyle(color: HsColors.onDuty, fontSize: 13)),
                ]),
              ),
              const Icon(Icons.chevron_right, color: HsColors.textSecondary),
            ]),
          ),
        ),
      ),
    );
  }
}

/// One trip: map of the plan and the route taken, totals, petrol, and every stop with the distance from the one before.
class TripDetailScreen extends StatefulWidget {
  const TripDetailScreen({super.key, required this.planName});
  final String planName;

  @override
  State<TripDetailScreen> createState() => _TripDetailScreenState();
}

class _TripDetailScreenState extends State<TripDetailScreen> {
  TripPlan? _trip;
  TripFuel? _fuel; // petrol of this trip and whether it is claimed
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final t = await ErpService.myTrip(widget.planName);
      try {
        final ex = await ErpService.myExpenses();
        _fuel = ex.fuelType == null ? null : ex.trips.where((x) => x.name == t.name).firstOrNull;
      } catch (_) {}
      if (mounted) {
        setState(() {
          _trip = t;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  bool _canEdit(TripPlan t) {
    if (t.status != 'Planned' && t.status != 'In Progress') return false;
    final d = t.date == null ? null : DateTime.tryParse(t.date!);
    final now = DateTime.now();
    return d == null || !d.isBefore(DateTime(now.year, now.month, now.day));
  }

  Future<void> _edit(TripPlan t) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => PlanTripScreen(edit: t)));
    if (saved == true) _load();
  }

  Future<void> _go(TripPlan t) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TripScreen(planName: t.name)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = _trip;
    final canGo = t != null && t.isToday && t.status != 'Completed' && t.status != 'Cancelled';
    return Scaffold(
      appBar: AppBar(title: Text(t?.title ?? 'Trip')),
      bottomNavigationBar: canGo
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  onPressed: () => _go(t),
                  icon: const Icon(Icons.navigation),
                  label: Text(t.done > 0 ? 'Continue trip' : 'Start trip'),
                ),
              ),
            )
          : null,
      body: t == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: EdgeInsets.zero, children: [
                SizedBox(height: 230, child: _map(t)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      Text(_dayLabel(t.date),
                          style: const TextStyle(color: HsColors.textSecondary, fontWeight: FontWeight.w600)),
                      const SizedBox(width: 8),
                      _statusChip(t.status),
                      const Spacer(),
                      Text('${t.done} of ${t.stops.length} reached', style: const TextStyle(fontWeight: FontWeight.w600)),
                    ]),
                    const SizedBox(height: 12),
                    _totals(t),
                    if (_canEdit(t)) ...[
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                        onPressed: () => _edit(t),
                        icon: const Icon(Icons.edit_road),
                        label: Text(t.done > 0 ? 'Change the stops still to visit' : 'Edit trip'),
                      ),
                    ],
                    if (_fuel != null) ...[const SizedBox(height: 10), _claim(_fuel!)],
                    const SizedBox(height: 18),
                    const Text('Stops', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: HsColors.navy)),
                    const SizedBox(height: 8),
                    _stops(t),
                    if (t.notes != null) ...[
                      const SizedBox(height: 14),
                      Text(t.notes!, style: const TextStyle(color: HsColors.textSecondary)),
                    ],
                  ]),
                ),
              ]),
            ),
    );
  }

  Widget _map(TripPlan t) {
    final stops = t.stops.where((s) => s.hasLocation).toList();
    final pts = [for (final s in stops) LatLng(s.lat!, s.lon!)];
    final track = [for (final p in t.track) LatLng(p[0], p[1])];
    final all = [...pts, ...track];
    if (all.isEmpty) return Container(color: HsColors.card);
    return FlutterMap(
      options: MapOptions(
        initialCenter: all.first,
        initialZoom: 13,
        initialCameraFit:
            all.length > 1 ? CameraFit.coordinates(coordinates: all, padding: const EdgeInsets.all(32), maxZoom: 16) : null,
      ),
      children: [
        hsTiles(),
        if (pts.length > 1)
          PolylineLayer(polylines: [
            Polyline(
              points: pts,
              strokeWidth: 3,
              color: HsColors.navy,
              pattern: StrokePattern.dashed(segments: const [10, 8]),
            ),
          ]),
        if (track.length > 1)
          PolylineLayer(polylines: [
            Polyline(points: track, strokeWidth: 5, color: HsColors.onDuty, borderStrokeWidth: 1.5, borderColor: Colors.white),
          ]),
        MarkerLayer(markers: [
          for (final s in stops)
            Marker(
              point: LatLng(s.lat!, s.lon!),
              width: 28,
              height: 28,
              child: StopBadge(number: t.stops.indexOf(s) + 1, status: s.status),
            ),
        ]),
        hsAttribution,
      ],
    );
  }

  /// Claim this trip's petrol as an expense (or show where it was claimed).
  Widget _claim(TripFuel f) {
    if (f.claimedIn != null) {
      return Row(children: [
        const Icon(Icons.check_circle, color: HsColors.onDuty, size: 20),
        const SizedBox(width: 6),
        Expanded(child: Text('Petrol claimed in ${f.claimedIn}', style: const TextStyle(color: HsColors.onDuty))),
      ]);
    }
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
      onPressed: f.amount <= 0
          ? () => showMyVehicle(context)
          : () async {
              final done = await Navigator.of(context)
                  .push<bool>(MaterialPageRoute(builder: (_) => NewClaimScreen(trip: f.name)));
              if (done == true) _load();
            },
      icon: const Icon(Icons.local_gas_station),
      label: Text(f.amount <= 0
          ? 'No vehicle mileage yet – ask the office'
          : 'Claim petrol ${hsMoney(f.amount)} (${f.km.toStringAsFixed(1)} km ${f.actual ? 'travelled' : 'planned'})'),
    );
  }

  Widget _totals(TripPlan t) {
    Widget stat(String value, String label, {Color color = HsColors.navy}) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: color)),
            Text(label, style: const TextStyle(color: HsColors.textSecondary, fontSize: 12)),
          ]),
        );
    return HsPanel(
      child: Column(children: [
        Row(children: [
          stat(hsKm(t.plannedKm), 'Planned distance'),
          stat(t.plannedMinutes > 0 ? hsDuration(t.plannedMinutes) : '–', 'Driving time'),
          stat(t.actualKm > 0 ? hsKm(t.actualKm) : '–', 'Travelled', color: HsColors.onDuty),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          stat(t.fuelLitres > 0 ? '${t.fuelLitres.toStringAsFixed(1)} L' : '–', 'Petrol needed'),
          stat(t.fuelCost > 0 ? hsMoney(t.fuelCost) : '–', 'Petrol cost'),
          stat(t.mileage > 0 ? '${t.mileage.toStringAsFixed(t.mileage % 1 == 0 ? 0 : 1)} km/l' : 'Not set', 'Mileage'),
        ]),
        if (t.started != null) ...[
          const SizedBox(height: 12),
          Row(children: [
            const Icon(Icons.schedule, size: 16, color: HsColors.textSecondary),
            const SizedBox(width: 6),
            Text('Started ${t.started}${t.finished != null ? ' · finished ${t.finished}' : ''}',
                style: const TextStyle(color: HsColors.textSecondary)),
          ]),
        ],
      ]),
    );
  }

  Widget _stops(TripPlan t) {
    final rows = <Widget>[];
    for (var i = 0; i < t.stops.length; i++) {
      final s = t.stops[i];
      if (s.legKm > 0 || s.legMinutes > 0) {
        rows.add(Padding(
          padding: const EdgeInsets.only(left: 14, top: 2, bottom: 2),
          child: Row(children: [
            Container(width: 2, height: 26, color: HsColors.border),
            const SizedBox(width: 18),
            const Icon(Icons.directions_car, size: 16, color: HsColors.blue),
            const SizedBox(width: 6),
            Text('${hsKm(s.legKm)} · ${hsDuration(s.legMinutes)}${i == 0 ? ' from the start' : ''}',
                style: const TextStyle(color: HsColors.blue, fontWeight: FontWeight.w600, fontSize: 13)),
          ]),
        ));
      }
      final when = [
        if (s.arrived != null) 'Reached ${s.arrived}' else if (s.planned != null) 'Planned ${s.planned}',
        if (s.left != null) 'left ${s.left}',
        if (s.minutes > 0) '${hsDuration(s.minutes)} there',
      ].join(' · ');
      rows.add(Material(
        color: HsColors.card,
        borderRadius: BorderRadius.circular(14),
        child: ListTile(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          onTap: () => showStopSheet(context, s, i + 1),
          leading: SizedBox(width: 30, height: 30, child: StopBadge(number: i + 1, status: s.status)),
          title: Text(s.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text([if (s.type != null) s.type!, if (when.isNotEmpty) when, if (s.address != null) s.address!].join('\n'),
              maxLines: 3, overflow: TextOverflow.ellipsis),
          trailing: s.phone != null
              ? IconButton(icon: const Icon(Icons.call, color: HsColors.onDuty), onPressed: () => callStop(context, s))
              : Text(stopStatusLabel(s.status), style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }
}

/// The vehicle the office assigned to this worker, its mileage and fuel price. Set in the ERP (Vehicle), not here.
Future<void> showMyVehicle(BuildContext context, {VehicleInfo? current}) async {
  var info = current;
  if (info == null) {
    try {
      info = await ErpService.myVehicle();
    } catch (_) {}
  }
  if (!context.mounted) return;
  final v = info;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.two_wheeler, color: HsColors.navy, size: 30),
            const SizedBox(width: 12),
            Expanded(
              child: Text(v?.label ?? 'Could not load your vehicle',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: HsColors.navy)),
            ),
          ]),
          const SizedBox(height: 14),
          if (v != null && v.vehicle != null) ...[
            if (v.make != null) _vline('Make', v.make!),
            if (v.fuelType != null) _vline('Fuel', v.fuelType!),
            _vline('Mileage', v.mileage > 0 ? '${v.mileage.toStringAsFixed(v.mileage % 1 == 0 ? 0 : 1)} km per litre${v.own ? '' : ' (company default)'}' : 'Not set'),
            if (v.fuelPrice > 0) _vline('Fuel price', '${hsMoney(v.fuelPrice)} a litre'),
          ],
          const SizedBox(height: 8),
          Text(
            v == null || v.vehicle == null
                ? 'The office assigns vehicles in the ERP (Vehicle > Employee). Ask them to assign yours so the fuel for your trips is worked out.'
                : 'Set by the office in the ERP. Ask them if something is wrong.',
            style: const TextStyle(color: HsColors.textSecondary),
          ),
        ]),
      ),
    ),
  );
}

Widget _vline(String k, String v) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [
        SizedBox(width: 90, child: Text(k, style: const TextStyle(color: HsColors.textSecondary))),
        Expanded(child: Text(v, style: const TextStyle(fontWeight: FontWeight.w600))),
      ]),
    );
