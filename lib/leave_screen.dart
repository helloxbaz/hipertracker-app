import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'app_theme.dart';
import 'erp_service.dart';

const _leaveColors = {
  'Open': Color(0xFFF59E0B),
  'Approved': HsColors.onDuty,
  'Rejected': HsColors.danger,
  'Cancelled': Color(0xFF9CA3AF),
};

String _leaveStatus(String s) => s == 'Open' ? 'Waiting for approval' : s;

String _days(double d) => d == d.roundToDouble() ? '${d.round()}' : d.toStringAsFixed(1);

String _date(String iso) {
  final d = DateTime.tryParse(iso);
  return d == null ? iso : DateFormat('d MMM').format(d);
}

/// Leave: what is left of each kind of leave, my applications and their approval, and apply for leave.
class LeaveScreen extends StatefulWidget {
  const LeaveScreen({super.key, this.embedded = false});

  /// Shown inside the Requests tab (no app bar; the + button applies for leave).
  final bool embedded;

  @override
  State<LeaveScreen> createState() => _LeaveScreenState();
}

class _LeaveScreenState extends State<LeaveScreen> {
  LeaveInfo? _info;
  String? _error;

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

  Future<void> _open(LeaveApplication a) async {
    final info = _info;
    if (info == null || !a.editable) return;
    final done = await Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => ApplyLeaveScreen(types: info.types, existing: a)));
    if (done == true) _load();
  }

  Future<void> _load() async {
    if (!ErpService.isConnected) return;
    try {
      final i = await ErpService.myLeave();
      if (mounted) {
        setState(() {
          _info = i;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _apply() async {
    final info = _info;
    if (info == null) return;
    final done = await Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => ApplyLeaveScreen(types: info.types)));
    if (done == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    return Scaffold(
      appBar: widget.embedded ? null : AppBar(title: const Text('Leave')),
      floatingActionButton: info == null || widget.embedded
          ? null
          : FloatingActionButton.extended(
              onPressed: _apply, icon: const Icon(Icons.event_busy), label: const Text('Apply for leave')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 96), children: [
          if (_error != null) ...[HsBanner(text: _error!, error: true), const SizedBox(height: 12)],
          if (info == null && _error == null)
            const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
          if (info != null) ...[
            const Text('Leave left', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: HsColors.navy)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final t in info.types)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(color: HsColors.card, borderRadius: BorderRadius.circular(12)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t.unpaid ? 'Unpaid' : (t.allocated ? '${_days(t.balance)} days' : 'Not given'),
                        style: TextStyle(
                            fontWeight: FontWeight.w800,
                            color: t.unpaid || t.balance > 0 ? HsColors.navy : HsColors.textSecondary)),
                    Text(t.name, style: const TextStyle(fontSize: 12, color: HsColors.textSecondary)),
                  ]),
                ),
            ]),
            const SizedBox(height: 20),
            const Text('My leave', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: HsColors.navy)),
            const SizedBox(height: 8),
            if (info.applications.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('No leave applied in the last three months.',
                    textAlign: TextAlign.center, style: TextStyle(color: HsColors.textSecondary)),
              ),
            for (final a in info.applications)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: a.editable ? () => _open(a) : null,
                  child: HsPanel(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(a.type, style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text(
                          '${a.from == a.to ? _date(a.from) : '${_date(a.from)} – ${_date(a.to)}'} · '
                          '${a.halfDay ? 'half day' : '${_days(a.days)} day${a.days == 1 ? '' : 's'}'}',
                          style: const TextStyle(color: HsColors.textSecondary),
                        ),
                        if (a.reason != null && a.reason!.trim().isNotEmpty)
                          Text(a.reason!.trim(), maxLines: 2, overflow: TextOverflow.ellipsis),
                        if (a.editable)
                          const Padding(
                            padding: EdgeInsets.only(top: 4),
                            child: Row(children: [
                              Icon(Icons.edit, size: 14, color: HsColors.blue),
                              SizedBox(width: 4),
                              Text('Tap to change or withdraw',
                                  style: TextStyle(color: HsColors.blue, fontSize: 12, fontWeight: FontWeight.w600)),
                            ]),
                          ),
                      ]),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: (_leaveColors[a.status] ?? HsColors.textSecondary).withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(_leaveStatus(a.status),
                          style: TextStyle(
                              color: _leaveColors[a.status] ?? HsColors.textSecondary,
                              fontSize: 12,
                              fontWeight: FontWeight.w700)),
                    ),
                  ]),
                ),
                ),
              ),
          ],
        ]),
      ),
    );
  }
}

/// Apply for leave: kind, first and last day (or half a day), and why.
class ApplyLeaveScreen extends StatefulWidget {
  const ApplyLeaveScreen({super.key, this.types, this.existing});

  /// Leave types with what is left (loaded here when not given).
  final List<LeaveType>? types;

  /// An application still waiting for approval, to change or withdraw.
  final LeaveApplication? existing;

  @override
  State<ApplyLeaveScreen> createState() => _ApplyLeaveScreenState();
}

class _ApplyLeaveScreenState extends State<ApplyLeaveScreen> {
  String? _type;
  late DateTime _from;
  late DateTime _to;
  bool _half = false;
  final _reason = TextEditingController();
  bool _saving = false;
  List<LeaveType> _types = const [];

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _from = DateTime(now.year, now.month, now.day);
    _to = _from;
    final e = widget.existing;
    if (e != null) {
      _from = DateTime.tryParse(e.from) ?? _from;
      _to = DateTime.tryParse(e.to) ?? _from;
      _half = e.halfDay;
      _reason.text = e.reason ?? '';
      _type = e.type;
    }
    if (widget.types != null) {
      _setTypes(widget.types!);
    } else {
      ErpService.myLeave().then((i) {
        if (mounted) setState(() => _setTypes(i.types));
      }).catchError((Object e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
      });
    }
  }

  void _setTypes(List<LeaveType> types) {
    _types = types;
    if (_type == null || !types.any((t) => t.name == _type)) {
      final usable = types.where((t) => t.balance > 0 || t.unpaid).toList();
      _type = usable.isNotEmpty ? usable.first.name : (types.isNotEmpty ? types.first.name : null);
    }
  }

  Future<void> _withdraw() async {
    final e = widget.existing;
    if (e == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Withdraw this leave?'),
        content: const Text('It will be removed and your manager will no longer see it.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: HsColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Withdraw'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ErpService.withdrawLeave(e.name);
      messenger.showSnackBar(const SnackBar(content: Text('Leave withdrawn.')));
      if (mounted) Navigator.of(context).pop(true);
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text(err.toString())));
    }
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _pick(bool first) async {
    final d = await showDatePicker(
      context: context,
      initialDate: first ? _from : _to,
      firstDate: DateTime.now().subtract(const Duration(days: 60)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (d == null) return;
    setState(() {
      if (first) {
        _from = d;
        if (_to.isBefore(d)) _to = d;
      } else {
        _to = d.isBefore(_from) ? _from : d;
      }
      if (_to != _from) _half = false;
    });
  }

  double get _dayCount => _half ? 0.5 : (_to.difference(_from).inDays + 1).toDouble();

  Future<void> _submit() async {
    final type = _type;
    if (type == null || _saving) return;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final name = await ErpService.applyLeave(type, _from, _to,
          halfDay: _half, reason: _reason.text.trim(), name: widget.existing?.name);
      messenger.showSnackBar(SnackBar(
          content: Text(widget.existing != null
              ? 'Leave changed ($name).'
              : 'Leave applied ($name). Your manager will approve it.')));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('EEE, d MMM yyyy');
    final chosen = _types.where((t) => t.name == _type).firstOrNull;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'Apply for leave' : 'Change leave'),
        actions: [
          if (widget.existing != null)
            TextButton.icon(
              onPressed: _withdraw,
              icon: const Icon(Icons.delete_outline, color: HsColors.danger),
              label: const Text('Withdraw', style: TextStyle(color: HsColors.danger)),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: _type == null || _saving ? null : _submit,
            icon: _saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.send),
            label: Text('${widget.existing == null ? 'Apply for' : 'Save'} ${_days(_dayCount)} day${_dayCount == 1 ? '' : 's'}'),
          ),
        ),
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        DropdownButtonFormField<String>(
          key: ValueKey('${_types.length}-$_type'),
          initialValue: _types.any((t) => t.name == _type) ? _type : null,
          decoration: const InputDecoration(labelText: 'Kind of leave', border: OutlineInputBorder()),
          items: [
            for (final t in _types)
              DropdownMenuItem(
                value: t.name,
                child: Text('${t.name}  ·  ${t.unpaid ? 'unpaid' : (t.allocated ? '${_days(t.balance)} left' : 'not given')}'),
              ),
          ],
          onChanged: (v) => setState(() => _type = v),
        ),
        if (chosen != null && !chosen.unpaid && chosen.balance < _dayCount)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: HsBanner(
                text: 'You may not have enough of this leave left. The ERP will check, or pick Leave Without Pay.'),
          ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(56), alignment: Alignment.centerLeft),
              onPressed: () => _pick(true),
              icon: const Icon(Icons.event),
              label: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                const Text('From', style: TextStyle(fontSize: 11)),
                Text(fmt.format(_from), style: const TextStyle(fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(56), alignment: Alignment.centerLeft),
              onPressed: () => _pick(false),
              icon: const Icon(Icons.event),
              label: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                const Text('To', style: TextStyle(fontSize: 11)),
                Text(fmt.format(_to), style: const TextStyle(fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
        ]),
        if (_from == _to)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Half day'),
            value: _half,
            onChanged: (v) => setState(() => _half = v),
          ),
        const SizedBox(height: 8),
        TextField(
          controller: _reason,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'Reason', border: OutlineInputBorder()),
        ),
      ]),
    );
  }
}
