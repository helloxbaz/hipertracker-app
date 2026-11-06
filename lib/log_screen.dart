import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'app_theme.dart';
import 'erp_service.dart';

/// More > Activity log: one day at a time — check in / out, trips, stops, location switched off, places reached.
class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  DateTime _day = DateTime.now();
  DayLog? _log;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final log = await ErpService.myLog(_day);
      if (mounted) setState(() => _log = log);
    } catch (e) {
      if (mounted) {
        setState(() {
          _log = null;
          _error = e.toString();
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool get _isToday {
    final n = DateTime.now();
    return _day.year == n.year && _day.month == n.month && _day.day == n.day;
  }

  void _shift(int days) {
    final d = _day.add(Duration(days: days));
    if (d.isAfter(DateTime.now())) return;
    _day = d;
    _load();
  }

  Future<void> _pick() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now(),
    );
    if (d == null) return;
    _day = d;
    _load();
  }

  static String _hours(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return h == 0 ? '${m}m' : '${h}h ${m.toString().padLeft(2, '0')}m';
  }

  static const _purple = Color(0xFF7C3AED);

  (IconData, Color, Color) _look(String kind) => switch (kind) {
        'in' => (Icons.login, HsColors.onDuty, HsColors.onDutyBg),
        'out' => (Icons.logout, HsColors.textSecondary, HsColors.offDutyBg),
        'trip' => (Icons.directions_car, Colors.white, HsColors.blue),
        'stop' => (Icons.local_parking, Colors.white, _purple),
        'gps_off' => (Icons.location_off, HsColors.danger, HsColors.dangerBg),
        'visit' => (Icons.flag, Colors.white, const Color(0xFFF59E0B)),
        _ => (Icons.circle, HsColors.textSecondary, HsColors.card),
      };

  Widget _stat(String value, String label, {Color color = HsColors.navy}) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: color)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(color: HsColors.textSecondary, fontSize: 12)),
        ]),
      );

  Widget _summary(DayLog log) => HsPanel(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Row(children: [
            _stat('${log.distanceKm.toStringAsFixed(1)} km', 'Travelled'),
            _stat(_hours(log.movingMinutes), '${log.trips} trip${log.trips == 1 ? '' : 's'}'),
            _stat(_hours(log.stoppedMinutes), '${log.stops} stop${log.stops == 1 ? '' : 's'}'),
          ]),
          const SizedBox(height: 14),
          Row(children: [
            _stat('${log.gpsOff}', 'Location switched off',
                color: log.gpsOff > 0 ? HsColors.danger : HsColors.navy),
            _stat(log.gpsOff > 0 ? _hours(log.gpsOffMinutes) : '–', 'Time without location',
                color: log.gpsOff > 0 ? HsColors.danger : HsColors.navy),
          ]),
        ]),
      );

  Widget _timeline(DayLog log) {
    return HsPanel(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(children: [
        for (var i = 0; i < log.items.length; i++)
          Builder(builder: (context) {
            final it = log.items[i];
            final look = _look(it.kind);
            return IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SizedBox(
                  width: 64,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 14, left: 12),
                    child: Text(DateFormat.jm().format(it.at),
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: HsColors.textSecondary)),
                  ),
                ),
                SizedBox(
                  width: 40,
                  child: Column(children: [
                    Container(width: 2, height: 10, color: i == 0 ? Colors.transparent : HsColors.border),
                    CircleAvatar(radius: 15, backgroundColor: look.$3, child: Icon(look.$1, size: 17, color: look.$2)),
                    Expanded(
                      child: Container(width: 2, color: i == log.items.length - 1 ? Colors.transparent : HsColors.border),
                    ),
                  ]),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 12, 12, 12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(it.title,
                          style: TextStyle(
                              fontWeight: FontWeight.w600, color: it.kind == 'gps_off' ? HsColors.danger : null)),
                      if (it.detail.isNotEmpty)
                        Text(it.detail, style: const TextStyle(color: HsColors.textSecondary, fontSize: 13)),
                    ]),
                  ),
                ),
              ]),
            );
          }),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final log = _log;
    final label = _isToday ? 'Today' : DateFormat('EEE, d MMM yyyy').format(_day);
    return Scaffold(
      appBar: AppBar(title: const Text('Activity log')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Row(children: [
            IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => _shift(-1)),
            Expanded(
              child: TextButton.icon(
                onPressed: _pick,
                icon: const Icon(Icons.calendar_today, size: 18),
                label: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ),
            IconButton(icon: const Icon(Icons.chevron_right), onPressed: _isToday ? null : () => _shift(1)),
          ]),
        ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
              if (_error != null) HsBanner(text: _error!, error: true),
              if (log != null) ...[
                _summary(log),
                const SizedBox(height: 16),
                if (log.items.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Text('Nothing recorded on this day.',
                        textAlign: TextAlign.center, style: TextStyle(color: HsColors.textSecondary)),
                  )
                else
                  _timeline(log),
              ],
            ]),
          ),
        ),
      ]),
    );
  }
}
