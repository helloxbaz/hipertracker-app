import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'app_theme.dart';
import 'erp_service.dart';
import 'stop_actions.dart';

/// Today's trip plan on a map: the stops in order (dashed line), the route travelled so far (blue),
/// and a Directions button that opens Google Maps through the stops still to visit.
class RouteMapScreen extends StatelessWidget {
  const RouteMapScreen({super.key, required this.plan, this.track = const []});

  final TripPlan plan;
  final List<List<double>> track;

  @override
  Widget build(BuildContext context) {
    final stops = plan.stops.where((s) => s.hasLocation).toList();
    final planLine = [for (final s in stops) LatLng(s.lat!, s.lon!)];
    final trackLine = [for (final p in track) LatLng(p[0], p[1])];
    final all = [...planLine, ...trackLine];
    final next = plan.next;

    return Scaffold(
      appBar: AppBar(title: Text(plan.title, overflow: TextOverflow.ellipsis)),
      body: Column(children: [
        Expanded(
          child: all.isEmpty
              ? const Center(child: Text('No stop has a location yet.', style: TextStyle(color: HsColors.textSecondary)))
              : FlutterMap(
                  options: MapOptions(
                    initialCenter: all.first,
                    initialZoom: 14,
                    initialCameraFit: all.length > 1
                        ? CameraFit.coordinates(coordinates: all, padding: const EdgeInsets.all(48), maxZoom: 16)
                        : null,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'org.traccar.client',
                    ),
                    if (trackLine.length > 1)
                      PolylineLayer(polylines: [
                        Polyline(points: trackLine, strokeWidth: 4, color: HsColors.blue.withValues(alpha: 0.8)),
                      ]),
                    if (planLine.length > 1)
                      PolylineLayer(polylines: [
                        Polyline(
                          points: planLine,
                          strokeWidth: 3,
                          color: HsColors.navy,
                          pattern: StrokePattern.dashed(segments: const [10, 8]),
                        ),
                      ]),
                    MarkerLayer(markers: [
                      if (trackLine.isNotEmpty)
                        Marker(
                          point: trackLine.last,
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
                      for (var i = 0; i < stops.length; i++)
                        Marker(
                          point: LatLng(stops[i].lat!, stops[i].lon!),
                          width: 34,
                          height: 34,
                          child: GestureDetector(
                            onTap: () => showStopSheet(context, stops[i], plan.stops.indexOf(stops[i]) + 1),
                            child: StopBadge(
                              number: plan.stops.indexOf(stops[i]) + 1,
                              status: stops[i].status,
                              highlight: identical(stops[i], next),
                            ),
                          ),
                        ),
                    ]),
                    const RichAttributionWidget(attributions: [TextSourceAttribution('OpenStreetMap contributors')]),
                  ],
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(
                next == null
                    ? 'All ${plan.stops.length} stops done'
                    : 'Next: ${next.name}  ·  ${plan.done} of ${plan.stops.length} done',
                style: const TextStyle(fontWeight: FontWeight.w600, color: HsColors.navy),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: plan.directions() == null ? null : () => openDirections(context, plan),
                icon: const Icon(Icons.directions),
                label: const Text('Directions through the remaining stops'),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
