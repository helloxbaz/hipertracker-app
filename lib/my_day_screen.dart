import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'app_theme.dart';
import 'erp_service.dart';

/// My Day tab: today's distance, time on duty and GPS-off count, then the check in / out history.
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
      if (mounted) setState(() {
        _day = day;
        _error = null;
      });
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
          _stat('${day.gpsOff}', 'GPS turned off', color: day.gpsOff > 0 ? HsColors.danger : HsColors.navy),
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

  List<Widget> _history(MyDay day) {
    // newest day first; inside a day, oldest log first
    final byDay = <DateTime, List<AttendanceLog>>{};
    for (final l in day.logs) {
      byDay.putIfAbsent(DateTime(l.time.year, l.time.month, l.time.day), () => []).add(l);
    }
    final now = DateTime.now();
    final out = <Widget>[];
    for (final entry in byDay.entries) {
      final logs = entry.value.reversed.toList();
      final isToday = _sameDay(entry.key, now);
      final label = isToday
          ? 'Today'
          : _sameDay(entry.key, now.subtract(const Duration(days: 1)))
              ? 'Yesterday'
              : DateFormat('EEE, d MMM').format(entry.key);
      out.add(Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
        child: Row(children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700, color: HsColors.navy)),
          const Spacer(),
          Text(_hours(_worked(logs, isToday: isToday)), style: const TextStyle(color: HsColors.textSecondary)),
        ]),
      ));
      out.add(HsPanel(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(children: [
          for (var i = 0; i < logs.length; i++) ...[
            if (i > 0) const Divider(indent: 56),
            ListTile(
              leading: CircleAvatar(
                radius: 16,
                backgroundColor: logs[i].isIn ? HsColors.onDutyBg : HsColors.offDutyBg,
                child: Icon(logs[i].isIn ? Icons.login : Icons.logout, size: 18,
                    color: logs[i].isIn ? HsColors.onDuty : HsColors.textSecondary),
              ),
              title: Text(logs[i].isIn ? 'Checked in' : 'Checked out'),
              subtitle: logs[i].lat == null ? const Text('No location') : null,
              trailing: Text(DateFormat.jm().format(logs[i].time), style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          ],
        ]),
      ));
    }
    return out;
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
                  if (day.logs.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Text('No check ins in the last two weeks.',
                          textAlign: TextAlign.center, style: TextStyle(color: HsColors.textSecondary)),
                    )
                  else
                    ..._history(day),
                ],
              ]),
            ),
    );
  }
}
