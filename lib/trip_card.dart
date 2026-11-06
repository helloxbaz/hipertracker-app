import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'app_theme.dart';
import 'erp_service.dart';
import 'map_tiles.dart';
import 'plan_trip_screen.dart';
import 'stop_actions.dart';
import 'trip_screen.dart';

/// Home: today's trip plan with a small map of the stops and a big Start / Continue trip button.
class TodayTripCard extends StatefulWidget {
  const TodayTripCard({super.key});

  @override
  State<TodayTripCard> createState() => _TodayTripCardState();
}

class _TodayTripCardState extends State<TodayTripCard> {
  List<TripPlan> _plans = const [];

  @override
  void initState() {
    super.initState();
    ErpService.changes.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    ErpService.changes.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    if (!ErpService.isConnected) return;
    try {
      final day = await ErpService.myDay(days: 1);
      if (mounted) setState(() => _plans = day.plans);
    } catch (_) {}
  }

  Future<void> _open(TripPlan plan) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TripScreen(planName: plan.name)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    if (!ErpService.isConnected) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final p in _plans) _card(p),
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: () async {
            await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PlanTripScreen()));
            _load();
          },
          icon: const Icon(Icons.add_road),
          label: Text(_plans.isEmpty ? 'Plan my trip' : 'Plan another trip'),
        ),
      ),
    ]);
  }

  Widget _card(TripPlan plan) {
    final stops = plan.stops.where((s) => s.hasLocation).toList();
    final pts = [for (final s in stops) LatLng(s.lat!, s.lon!)];
    final next = plan.next;
    final started = plan.done > 0;
    final finished = next == null;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Material(
        color: HsColors.card,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _open(plan),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (pts.isNotEmpty)
              SizedBox(
                height: 150,
                child: IgnorePointer(
                  child: FlutterMap(
                    options: MapOptions(
                      initialCenter: pts.first,
                      initialZoom: 13,
                      initialCameraFit: pts.length > 1
                          ? CameraFit.coordinates(coordinates: pts, padding: const EdgeInsets.all(28), maxZoom: 15)
                          : null,
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
                      MarkerLayer(markers: [
                        for (final s in stops)
                          Marker(
                            point: LatLng(s.lat!, s.lon!),
                            width: 26,
                            height: 26,
                            child: StopBadge(
                                number: plan.stops.indexOf(s) + 1, status: s.status, highlight: identical(s, next)),
                          ),
                      ]),
                    ],
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  const Icon(Icons.route, color: HsColors.navy),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(plan.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: HsColors.navy)),
                  ),
                  Text('${plan.done}/${plan.stops.length}', style: const TextStyle(fontWeight: FontWeight.w700)),
                ]),
                const SizedBox(height: 4),
                Text(
                  next == null
                      ? 'All stops done'
                      : '${started ? 'Next' : 'First'}: ${next.name}${next.planned != null ? ' · ${next.planned}' : ''}',
                  style: const TextStyle(color: HsColors.textSecondary),
                ),
                if (plan.plannedKm > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      [
                        hsKm(plan.plannedKm),
                        if (plan.plannedMinutes > 0) '${hsDuration(plan.plannedMinutes)} driving',
                        if (plan.fuelLitres > 0) '${plan.fuelLitres.toStringAsFixed(1)} L petrol',
                        if (plan.fuelCost > 0) hsMoney(plan.fuelCost),
                      ].join(' · '),
                      style: const TextStyle(color: HsColors.blue, fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                  ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: plan.stops.isEmpty ? 0 : plan.done / plan.stops.length,
                    minHeight: 6,
                    color: HsColors.onDuty,
                    backgroundColor: HsColors.cardHigh,
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    backgroundColor: finished ? HsColors.onDuty : HsColors.blue,
                    textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                  onPressed: () => _open(plan),
                  icon: Icon(finished ? Icons.map_outlined : Icons.navigation),
                  label: Text(finished ? 'View trip' : (started ? 'Continue trip' : 'Start trip')),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
