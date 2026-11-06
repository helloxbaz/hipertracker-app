import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'app_theme.dart';
import 'erp_service.dart';
import 'log_screen.dart';
import 'plan_trip_screen.dart';
import 'stop_actions.dart';
import 'trip_screen.dart';
import 'trips_screen.dart';

/// My Day tab: today's distance, time on duty and location-off count, today's trip plans, plan my trip.
/// The full history (trips, stops, check ins, location off) is in More > Activity log.
class MyDayScreen extends StatefulWidget {
  const MyDayScreen({super.key});

  @override
  State<MyDayScreen> createState() => _MyDayScreenState();
}

class _MyDayScreenState extends State<MyDayScreen> {
  MyDay? _day;
  String? _error;
  bool _loading = false;

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
    if (!ErpService.isConnected || _loading) return;
    setState(() => _loading = true);
    try {
      final day = await ErpService.myDay();
      if (mounted) {
        setState(() {
          _day = day;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  static bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  /// Time between each check in and the next check out on that day (an open check in today counts until now).
  static Duration _worked(List<AttendanceLog> dayLogsAsc, {bool isToday = false}) {
    var total = Duration.zero;
    DateTime? openIn;
    for (final l in dayLogsAsc) {
      if (l.isIn) {
        openIn ??= l.time;
      } else if (openIn != null) {
        total += l.time.difference(openIn);
        openIn = null;
      }
    }
    if (openIn != null && isToday) total += DateTime.now().difference(openIn);
    return total;
  }

  static String _hours(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    return h == 0 ? '${m}m' : '${h}h ${m.toString().padLeft(2, '0')}m';
  }

  Widget _stat(String value, String label, {Color color = HsColors.navy}) {
    return Expanded(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: color)),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(color: HsColors.textSecondary, fontSize: 12)),
      ]),
    );
  }

  Widget _todayCard(MyDay day) {
    final now = DateTime.now();
    final todayLogs = day.logs.where((l) => _sameDay(l.time, now)).toList().reversed.toList();
    final worked = _worked(todayLogs, isToday: true);
    return HsPanel(
      padding: const EdgeInsets.all(18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Today', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: HsColors.navy)),
        const SizedBox(height: 14),
        Row(children: [
          _stat('${day.distanceKm.toStringAsFixed(1)} km', 'Travelled'),
          _stat(_hours(worked), 'On duty'),
          _stat('${day.gpsOff}', 'Location off', color: day.gpsOff > 0 ? HsColors.danger : HsColors.navy),
        ]),
        if (day.first != null) ...[
          const SizedBox(height: 12),
          Text(
            'First location ${DateFormat.jm().format(day.first!)} · last ${DateFormat.jm().format(day.last!)}',
            style: const TextStyle(color: HsColors.textSecondary, fontSize: 13),
          ),
        ],
      ]),
    );
  }

  Future<void> _push(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
    _load();
  }

  Widget _action(IconData icon, String title, String subtitle, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          tileColor: HsColors.card,
          leading: CircleAvatar(
            backgroundColor: HsColors.navy,
            child: Icon(icon, color: Colors.white, size: 20),
          ),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(subtitle, style: const TextStyle(color: HsColors.textSecondary)),
          trailing: const Icon(Icons.chevron_right),
          onTap: onTap,
        ),
      );

  void _startTrip(TripPlan plan) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TripScreen(planName: plan.name)));

  /// A trip plan from the office: the stops in order; reached / done is marked by the ERP from the phone's location.
  Widget _plan(TripPlan plan, MyDay day) {
    final next = plan.next;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
        child: Row(children: [
          Expanded(
            child: Text(plan.title,
                style: const TextStyle(fontWeight: FontWeight.w700, color: HsColors.navy), overflow: TextOverflow.ellipsis),
          ),
          Text('${plan.done} of ${plan.stops.length} done', style: const TextStyle(color: HsColors.textSecondary)),
        ]),
      ),
      HsPanel(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(children: [
          for (var i = 0; i < plan.stops.length; i++) ...[
            if (i > 0) const Divider(indent: 56),
            Builder(builder: (context) {
              final s = plan.stops[i];
              final isNext = identical(s, next);
              final parts = <String>[
                if (s.arrived != null) 'Reached ${s.arrived}' else if (s.planned != null) 'Planned ${s.planned}',
                if (s.left != null) 'left ${s.left}',
                if (s.type != null) s.type!,
              ];
              return ListTile(
                tileColor: isNext ? HsColors.cardHigh : null,
                onTap: () => showStopSheet(context, s, i + 1, onNavigate: () => _startTrip(plan)),
                leading: SizedBox(width: 32, height: 32, child: StopBadge(number: i + 1, status: s.status)),
                title: Text(isNext ? 'Next: ${s.name}' : s.name,
                    style: TextStyle(fontWeight: isNext ? FontWeight.w700 : FontWeight.w500)),
                subtitle: parts.isEmpty ? null : Text(parts.join(' · ')),
                trailing: s.pending && s.hasLocation
                    ? IconButton(
                        tooltip: 'Navigate',
                        icon: const Icon(Icons.navigation, color: HsColors.blue),
                        onPressed: () => _startTrip(plan),
                      )
                    : Text(stopStatusLabel(s.status), style: const TextStyle(fontWeight: FontWeight.w600)),
              );
            }),
          ],
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Row(children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _startTrip(plan),
                  icon: const Icon(Icons.navigation),
                  label: Text(plan.next == null ? 'View trip' : (plan.done > 0 ? 'Continue trip' : 'Start trip')),
                ),
              ),
            ]),
          ),
        ]),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final day = _day;
    return Scaffold(
      appBar: AppBar(title: const Text('My Day')),
      body: !ErpService.isConnected
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Text('Sign in with your ERP account to see your attendance.',
                    textAlign: TextAlign.center, style: TextStyle(color: HsColors.textSecondary)),
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
                if (_error != null) ...[HsBanner(text: _error!, error: true), const SizedBox(height: 12)],
                if (day == null && _error == null)
                  const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
                if (day != null) ...[
                  _todayCard(day),
                  for (final plan in day.plans) _plan(plan, day),
                  const SizedBox(height: 18),
                  _action(Icons.add_road, 'Plan my trip', 'Pick customers to visit — we suggest the best order',
                      () => _push(const PlanTripScreen())),
                  _action(Icons.route, 'My trips', 'Every trip with distance, time and petrol',
                      () => _push(const TripsScreen())),
                  _action(Icons.history, 'Activity log', 'Trips, stops, check ins and location off, day by day',
                      () => _push(const LogScreen())),
                ],
              ]),
            ),
    );
  }
}
