import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'app_theme.dart';
import 'erp_service.dart';
import 'map_tiles.dart';
import 'trip_screen.dart';
import 'trips_screen.dart';

/// The worker plans their own trip: pick customers / leads / deals to visit, the app suggests the best order
/// from where they are and draws the road route, then saves it as a Trip Plan the office sees in the ERP.
class PlanTripScreen extends StatefulWidget {
  const PlanTripScreen({super.key, this.edit});

  /// A trip to change: its stops still to visit are loaded, and saving updates it (stops already reached stay).
  final TripPlan? edit;

  @override
  State<PlanTripScreen> createState() => _PlanTripScreenState();
}

class _PlanTripScreenState extends State<PlanTripScreen> {
  final _map = MapController();
  final _search = TextEditingController();
  Timer? _searchTimer;
  Timer? _routeTimer;

  Position? _pos;
  List<VisitPlace> _places = const [];
  final List<VisitPlace> _chosen = [];
  bool _loading = true;
  String? _error;
  bool _manual = false; // the worker moved stops by hand, so don't reorder them
  bool _ordering = false;
  String? _orderNote;
  RoutePlan? _route;
  bool _saving = false;
  bool _mapReady = false;
  VehicleInfo? _vehicle;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _routeTimer?.cancel();
    _search.dispose();
    super.dispose();
  }

  List<double>? get _here => _pos == null ? null : [_pos!.latitude, _pos!.longitude];

  Future<void> _loadVehicle() async {
    try {
      final v = await ErpService.myVehicle();
      if (mounted) setState(() => _vehicle = v);
    } catch (_) {}
  }

  Future<void> _editMileage() => showMyVehicle(context, current: _vehicle);

  Future<void> _start() async {
    _loadVehicle();
    final edit = widget.edit;
    if (edit != null) {
      _chosen.addAll([for (final s in edit.stops) if (s.pending && s.hasLocation) VisitPlace.fromStop(s)]);
      _manual = true; // keep their order unless they ask for the best order
    }
    try {
      if (await Geolocator.isLocationServiceEnabled()) {
        var perm = await Geolocator.checkPermission();
        if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
        if (perm == LocationPermission.always || perm == LocationPermission.whileInUse) {
          _pos = await Geolocator.getLastKnownPosition();
          try {
            _pos = await Geolocator.getCurrentPosition(
              locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 15)),
            );
          } catch (_) {}
        }
      }
    } catch (_) {}
    await _loadPlaces();
  }

  Future<void> _loadPlaces() async {
    setState(() => _loading = true);
    try {
      final list = await ErpService.visitPlaces(lat: _pos?.latitude, lon: _pos?.longitude, q: _search.text.trim());
      if (mounted) {
        setState(() {
          _places = list;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    _fit();
  }

  void _onSearch(String _) {
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(milliseconds: 450), _loadPlaces);
  }

  bool _isChosen(VisitPlace p) => _chosen.any((c) => c.key == p.key);

  void _toggle(VisitPlace p) {
    setState(() {
      if (_isChosen(p)) {
        _chosen.removeWhere((c) => c.key == p.key);
      } else {
        _chosen.add(p);
      }
    });
    _changed();
  }

  /// After adding / removing: suggest the order again (unless moved by hand) and redraw the road route.
  void _changed() {
    _routeTimer?.cancel();
    _routeTimer = Timer(const Duration(milliseconds: 600), () async {
      if (!_manual) await _bestOrder(quiet: true);
      await _drawRoute();
    });
  }

  Future<void> _bestOrder({bool quiet = false}) async {
    final here = _here;
    if (_chosen.length < 2) {
      setState(() => _orderNote = null);
      return;
    }
    if (here == null) {
      if (!quiet) _snack('Your location is not known yet, so the order can\'t be worked out.');
      return;
    }
    setState(() => _ordering = true);
    try {
      final picked = List<VisitPlace>.of(_chosen);
      final order = await ErpService.bestOrder(here, [for (final p in picked) [p.lat, p.lon]]);
      if (!mounted) return;
      setState(() {
        _chosen
          ..clear()
          ..addAll([for (final i in order) picked[i]]);
        _manual = false;
        _orderNote = 'Best order from where you are: start with ${_chosen.first.title}';
      });
    } catch (e) {
      if (!quiet) _snack(e.toString());
    } finally {
      if (mounted) setState(() => _ordering = false);
    }
  }

  Future<void> _drawRoute() async {
    final here = _here;
    if (_chosen.isEmpty) {
      setState(() => _route = null);
      return;
    }
    final from = here ?? [_chosen.first.lat, _chosen.first.lon];
    final stops = [for (final p in (here == null ? _chosen.skip(1) : _chosen)) [p.lat, p.lon]];
    if (stops.isEmpty) {
      setState(() => _route = null);
      return;
    }
    try {
      final r = await ErpService.route(from, stops);
      if (mounted) setState(() => _route = r);
    } catch (_) {
      if (mounted) setState(() => _route = null);
    }
    _fit();
  }

  void _fit() {
    if (!_mapReady) return;
    final pts = <LatLng>[
      if (_pos != null) LatLng(_pos!.latitude, _pos!.longitude),
      for (final p in (_chosen.isNotEmpty ? _chosen : _places.take(15))) LatLng(p.lat, p.lon),
    ];
    if (pts.isEmpty) return;
    if (pts.length == 1) {
      _map.move(pts.first, 14);
    } else {
      _map.fitCamera(CameraFit.coordinates(coordinates: pts, padding: const EdgeInsets.all(36), maxZoom: 16));
    }
  }

  void _snack(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _save() async {
    if (_chosen.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      _routeTimer?.cancel();
      if (!_manual && _chosen.length > 1) await _bestOrder(quiet: true);
      final edit = widget.edit;
      if (edit != null) {
        await ErpService.editMyTrip(edit.name, _chosen, start: _here);
        if (mounted) Navigator.of(context).pop(true);
        return;
      }
      final name = await ErpService.saveMyTrip(_chosen, start: _here);
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => TripScreen(planName: name)));
    } catch (e) {
      if (mounted) _snack(e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static String _km(double m) => m >= 1000 ? '${(m / 1000).toStringAsFixed(1)} km' : '${m.round()} m';

  static String _mins(int s) {
    final m = (s / 60).round();
    return m < 60 ? '$m min' : '${m ~/ 60} h ${m % 60} min';
  }

  // ---------------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    return Scaffold(
      appBar: AppBar(title: Text(widget.edit == null ? 'Plan my trip' : 'Edit ${widget.edit!.title}')),
      body: Column(children: [
        SizedBox(height: math.max(200, h * 0.34), child: _mapView()),
        if (_route != null) _summary(_route!),
        if (_loading || _ordering) const LinearProgressIndicator(minHeight: 2),
        Expanded(child: _list()),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(children: [
            OutlinedButton.icon(
              onPressed: _chosen.length < 2 || _ordering
                  ? null
                  : () async {
                      await _bestOrder();
                      await _drawRoute();
                    },
              icon: const Icon(Icons.auto_awesome),
              label: const Text('Best order'),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                onPressed: _chosen.isEmpty || _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.navigation),
                label: Text(_chosen.isEmpty
                    ? 'Pick places to visit'
                    : (widget.edit == null ? 'Save & start trip' : 'Save changes')),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  /// Whole trip: road km, driving time, when it would end if started now, petrol needed and its cost.
  Widget _summary(RoutePlan r) {
    final km = r.distance / 1000.0;
    final mins = (r.duration / 60).round();
    final v = _vehicle;
    final end = DateTime.now().add(Duration(minutes: mins));
    Widget stat(String value, String label) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
            Text(label, style: const TextStyle(color: Color(0xFFBFD3E6), fontSize: 11)),
          ]),
        );
    return Container(
      width: double.infinity,
      color: HsColors.navy,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          stat(hsKm(km), 'Total distance'),
          stat(hsDuration(mins), 'Driving time'),
          stat(v != null && v.mileage > 0 ? '${v.litres(km).toStringAsFixed(1)} L' : '–', 'Petrol'),
          stat(v != null && v.mileage > 0 && v.fuelPrice > 0 ? hsMoney(v.cost(km)) : '–', 'Petrol cost'),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: Text(
              '${_chosen.length} stop${_chosen.length == 1 ? '' : 's'} · driving done by ${TimeOfDay.fromDateTime(end).format(context)} if you start now',
              style: const TextStyle(color: Color(0xFFD6E6F5), fontSize: 12),
            ),
          ),
          InkWell(
            onTap: _editMileage,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.local_gas_station, size: 15, color: Colors.white),
                const SizedBox(width: 3),
                Text(
                  v != null && v.mileage > 0
                      ? '${v.vehicle ?? 'Vehicle'} · ${v.mileage.toStringAsFixed(v.mileage % 1 == 0 ? 0 : 1)} km/l'
                      : 'No vehicle mileage',
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700, decoration: TextDecoration.underline, decorationColor: Colors.white),
                ),
                const SizedBox(width: 2),
                const Icon(Icons.info_outline, size: 13, color: Colors.white),
              ]),
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _mapView() {
    final chosenKeys = {for (final c in _chosen) c.key};
    return FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: _pos != null ? LatLng(_pos!.latitude, _pos!.longitude) : const LatLng(10.55, 76.3),
        initialZoom: _pos != null ? 13 : 8,
        onMapReady: () {
          _mapReady = true;
          _fit();
        },
      ),
      children: [
        hsTiles(),
        if (_route != null && _route!.line.length > 1)
          PolylineLayer(polylines: [
            Polyline(
              points: [for (final p in _route!.line) LatLng(p[0], p[1])],
              strokeWidth: 6,
              color: HsColors.blue,
              borderStrokeWidth: 2,
              borderColor: Colors.white,
            ),
          ]),
        MarkerLayer(markers: [
          for (final p in _places.take(150))
            if (!chosenKeys.contains(p.key))
              Marker(
                point: LatLng(p.lat, p.lon),
                width: 22,
                height: 22,
                child: GestureDetector(
                  onTap: () => _toggle(p),
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF94A3B8),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                ),
              ),
          for (var i = 0; i < _chosen.length; i++)
            Marker(
              point: LatLng(_chosen[i].lat, _chosen[i].lon),
              width: 30,
              height: 30,
              child: GestureDetector(
                onTap: () => _toggle(_chosen[i]),
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: HsColors.navy,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 4)],
                  ),
                  child: Text('${i + 1}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                ),
              ),
            ),
          if (_pos != null)
            Marker(
              point: LatLng(_pos!.latitude, _pos!.longitude),
              width: 22,
              height: 22,
              child: Container(
                decoration: BoxDecoration(
                  color: HsColors.blue,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 3),
                  boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 5)],
                ),
              ),
            ),
        ]),
        hsAttribution,
      ],
    );
  }

  Widget _list() {
    final rest = _places.where((p) => !_isChosen(p)).toList();
    return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 16), children: [
      if (_error != null) ...[HsBanner(text: _error!, error: true), const SizedBox(height: 10)],
      if (_pos == null && !_loading)
        const Padding(
          padding: EdgeInsets.only(bottom: 10),
          child: HsBanner(text: 'Your location is not known yet. Turn on location to sort places by distance.'),
        ),
      if (_chosen.isNotEmpty) ...[
        Row(children: [
          const Expanded(
            child: Text('Your stops', style: TextStyle(fontWeight: FontWeight.w700, color: HsColors.navy, fontSize: 16)),
          ),
          Text(_manual ? 'Your order' : 'Hold and drag to change',
              style: const TextStyle(color: HsColors.textSecondary, fontSize: 12)),
        ]),
        if (_orderNote != null && !_manual)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(children: [
              const Icon(Icons.auto_awesome, size: 16, color: HsColors.onDuty),
              const SizedBox(width: 6),
              Expanded(child: Text(_orderNote!, style: const TextStyle(color: HsColors.onDuty, fontSize: 13))),
            ]),
          ),
        const SizedBox(height: 8),
        HsPanel(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _chosen.length,
            onReorderItem: (from, to) {
              setState(() {
                _chosen.insert(to, _chosen.removeAt(from));
                _manual = true;
              });
              _changed();
            },
            itemBuilder: (context, i) {
              final p = _chosen[i];
              final li = _pos != null ? i : i - 1; // without a location the route starts at stop 1
              final leg = _route != null && li >= 0 && li < _route!.legs.length ? _route!.legs[li] : null;
              return ListTile(
                key: ValueKey(p.key),
                leading: CircleAvatar(
                  radius: 15,
                  backgroundColor: HsColors.navy,
                  child: Text('${i + 1}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                ),
                title: Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p.isPoint ? 'Point on the map' : p.type),
                  if (leg != null)
                    Row(children: [
                      const Icon(Icons.directions_car, size: 14, color: HsColors.blue),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          '${_km(leg[0].toDouble())} · ${_mins(leg[1])} from ${i == 0 ? 'you' : 'stop $i'}',
                          style: const TextStyle(color: HsColors.blue, fontWeight: FontWeight.w600, fontSize: 13),
                        ),
                      ),
                    ]),
                ]),
                isThreeLine: leg != null,
                trailing: IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.close),
                  onPressed: () => _toggle(p),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 18),
      ],
      TextField(
        controller: _search,
        onChanged: _onSearch,
        decoration: InputDecoration(
          hintText: 'Search customers, leads, deals…',
          prefixIcon: const Icon(Icons.search),
          filled: true,
          fillColor: HsColors.card,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
          isDense: true,
        ),
      ),
      const SizedBox(height: 12),
      Text(_pos == null ? 'Places to visit' : 'Places near you',
          style: const TextStyle(fontWeight: FontWeight.w700, color: HsColors.navy, fontSize: 16)),
      const SizedBox(height: 6),
      if (!_loading && rest.isEmpty)
        const Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            'No places found. A customer, lead or deal shows here once its location is set in the ERP.',
            textAlign: TextAlign.center,
            style: TextStyle(color: HsColors.textSecondary),
          ),
        ),
      for (final p in rest.take(100))
        Card(
          elevation: 0,
          color: HsColors.card,
          margin: const EdgeInsets.only(bottom: 6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: ListTile(
            onTap: () => _toggle(p),
            leading: const Icon(Icons.storefront_outlined, color: HsColors.navy),
            title: Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(p.type),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (p.km != null)
                Text(p.km! < 1 ? '${(p.km! * 1000).round()} m' : '${p.km!.toStringAsFixed(1)} km',
                    style: const TextStyle(color: HsColors.textSecondary)),
              const SizedBox(width: 4),
              const Icon(Icons.add_circle, color: HsColors.blue),
            ]),
          ),
        ),
    ]);
  }
}
