import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'app_theme.dart';
import 'erp_service.dart';

const _claimColors = {
  'Waiting for approval': Color(0xFFF59E0B),
  'Draft': Color(0xFFF59E0B),
  'Unpaid': HsColors.blue,
  'Paid': HsColors.onDuty,
  'Approved': HsColors.onDuty,
  'Rejected': HsColors.danger,
  'Cancelled': Color(0xFF9CA3AF),
};

String _date(String iso) {
  final d = DateTime.tryParse(iso);
  return d == null ? iso : DateFormat('d MMM').format(d);
}

Widget _chip(String text) {
  final c = _claimColors[text] ?? HsColors.textSecondary;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)),
    child: Text(text, style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w700)),
  );
}

/// Expense claims: my claims and their approval, and make a new one (trip petrol fills in by itself).
class ExpensesScreen extends StatefulWidget {
  const ExpensesScreen({super.key, this.embedded = false});

  /// Shown inside the Requests tab (no app bar; the + button makes a claim).
  final bool embedded;

  @override
  State<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends State<ExpensesScreen> {
  ExpenseInfo? _info;
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

  Future<void> _edit(ExpenseClaim c) async {
    if (!c.editable) return;
    final done = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => NewClaimScreen(existing: c)));
    if (done == true) _load();
  }

  Future<void> _load() async {
    if (!ErpService.isConnected) return;
    try {
      final i = await ErpService.myExpenses();
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

  Future<void> _new() async {
    final done = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const NewClaimScreen()));
    if (done == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final unclaimed = info?.trips.where((t) => t.claimedIn == null && t.amount > 0).toList() ?? const <TripFuel>[];
    return Scaffold(
      appBar: widget.embedded ? null : AppBar(title: const Text('Expense claims')),
      floatingActionButton: widget.embedded
          ? null
          : FloatingActionButton.extended(onPressed: _new, icon: const Icon(Icons.add), label: const Text('New claim')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 96), children: [
          if (_error != null) ...[HsBanner(text: _error!, error: true), const SizedBox(height: 12)],
          if (info == null && _error == null)
            const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
          if (unclaimed.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: HsPanel(
                color: HsColors.onDutyBg,
                child: Row(children: [
                  const Icon(Icons.local_gas_station, color: HsColors.onDuty),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Petrol for ${unclaimed.length} trip${unclaimed.length == 1 ? '' : 's'} not claimed yet: '
                      '${hsMoney(unclaimed.fold(0.0, (a, t) => a + t.amount))}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  TextButton(onPressed: _new, child: const Text('Claim')),
                ]),
              ),
            ),
          if (info != null && info.claims.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No claims yet.', textAlign: TextAlign.center, style: TextStyle(color: HsColors.textSecondary)),
            ),
          for (final c in info?.claims ?? const <ExpenseClaim>[])
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: c.editable ? () => _edit(c) : null,
                child: HsPanel(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text(hsMoney(c.claimed),
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: HsColors.navy)),
                    const SizedBox(width: 8),
                    Text(_date(c.date), style: const TextStyle(color: HsColors.textSecondary)),
                    const Spacer(),
                    _chip(c.approval == 'Rejected' ? 'Rejected' : c.status),
                  ]),
                  const SizedBox(height: 6),
                  for (final it in c.items)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Icon(it.trip != null ? Icons.local_gas_station : Icons.receipt_long,
                            size: 16, color: HsColors.textSecondary),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${it.type}${it.description != null && it.description!.isNotEmpty ? ' – ${it.description}' : ''}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                        Text(hsMoney(it.amount), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      ]),
                    ),
                  if (c.sanctioned > 0 && c.sanctioned != c.claimed)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('Approved ${hsMoney(c.sanctioned)}',
                          style: const TextStyle(color: HsColors.onDuty, fontWeight: FontWeight.w600)),
                    ),
                  if (c.editable)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Row(children: [
                        Icon(Icons.edit, size: 14, color: HsColors.blue),
                        SizedBox(width: 4),
                        Text('Tap to change or withdraw',
                            style: TextStyle(color: HsColors.blue, fontSize: 12, fontWeight: FontWeight.w600)),
                      ]),
                    ),
                ]),
              ),
              ),
            ),
        ]),
      ),
    );
  }
}

class _Other {
  String type;
  DateTime date;
  double amount;
  String note;
  _Other(this.type, this.date, this.amount, this.note);
}

/// A new claim: tick the trips whose petrol to claim (the amount comes from the trip), add other expenses, send.
class NewClaimScreen extends StatefulWidget {
  const NewClaimScreen({super.key, this.trip, this.existing});

  /// A trip to claim the petrol of (ticked when the screen opens).
  final String? trip;

  /// A claim still waiting for approval, to change or withdraw.
  final ExpenseClaim? existing;

  @override
  State<NewClaimScreen> createState() => _NewClaimScreenState();
}

class _NewClaimScreenState extends State<NewClaimScreen> {
  ExpenseInfo? _info;
  String? _error;
  final Set<String> _trips = {};
  final List<_Other> _others = [];
  final _remark = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _remark.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final i = await ErpService.myExpenses();
      if (!mounted) return;
      setState(() {
        _info = i;
        _error = null;
        final t = widget.trip;
        if (t != null && i.trips.any((x) => x.name == t && x.claimedIn == null && x.amount > 0)) _trips.add(t);
        final e = widget.existing;
        if (e != null && _trips.isEmpty && _others.isEmpty) {
          for (final it in e.items) {
            if (it.trip != null) {
              _trips.add(it.trip!);
            } else {
              _others.add(_Other(it.type, DateTime.tryParse(it.date) ?? DateTime.now(), it.amount, it.description ?? ''));
            }
          }
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  double get _total {
    final info = _info;
    if (info == null) return 0;
    final trips = info.trips.where((t) => _trips.contains(t.name)).fold(0.0, (a, t) => a + t.amount);
    return trips + _others.fold(0.0, (a, o) => a + o.amount);
  }

  Future<void> _editOther([_Other? existing]) async {
    final info = _info;
    if (info == null || info.types.isEmpty) return;
    final others = info.types.where((t) => t != info.fuelType || info.types.length == 1).toList();
    var type = existing?.type ?? (others.isNotEmpty ? others.first : info.types.first);
    var date = existing?.date ?? DateTime.now();
    final amount = TextEditingController(text: existing == null ? '' : existing.amount.toStringAsFixed(0));
    final note = TextEditingController(text: existing?.note ?? '');
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, MediaQuery.of(ctx).viewInsets.bottom + 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Expense', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: HsColors.navy)),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: type,
              decoration: const InputDecoration(labelText: 'Kind of expense', border: OutlineInputBorder()),
              items: [for (final t in info.types) DropdownMenuItem(value: t, child: Text(t))],
              onChanged: (v) => setSheet(() => type = v ?? type),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: amount,
                  autofocus: existing == null,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Amount', prefixText: '₹ ', border: OutlineInputBorder()),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 56)),
                onPressed: () async {
                  final d = await showDatePicker(
                      context: ctx,
                      initialDate: date,
                      firstDate: DateTime.now().subtract(const Duration(days: 120)),
                      lastDate: DateTime.now());
                  if (d != null) setSheet(() => date = d);
                },
                icon: const Icon(Icons.event),
                label: Text(DateFormat('d MMM').format(date)),
              ),
            ]),
            const SizedBox(height: 12),
            TextField(
              controller: note,
              decoration: const InputDecoration(labelText: 'What for', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 14),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(existing == null ? 'Add' : 'Save'),
            ),
          ]),
        ),
      ),
    );
    final value = double.tryParse(amount.text.trim()) ?? 0;
    if (ok != true || value <= 0) return;
    setState(() {
      if (existing != null) {
        existing
          ..type = type
          ..date = date
          ..amount = value
          ..note = note.text.trim();
      } else {
        _others.add(_Other(type, date, value, note.text.trim()));
      }
    });
  }

  Future<void> _submit() async {
    if (_saving || (_trips.isEmpty && _others.isEmpty)) return;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    String d(DateTime x) => '${x.year}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
    try {
      final name = await ErpService.claimExpense([
        for (final t in _trips) {'trip': t},
        for (final o in _others) {'type': o.type, 'date': d(o.date), 'amount': o.amount, 'description': o.note},
      ], remark: _remark.text.trim(), claim: widget.existing?.name);
      messenger.showSnackBar(SnackBar(
          content: Text(widget.existing != null ? 'Claim $name changed.' : 'Claim $name sent for approval.')));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool _free(TripFuel t) => t.amount > 0 && (t.claimedIn == null || t.claimedIn == widget.existing?.name);

  Future<void> _withdraw() async {
    final e = widget.existing;
    if (e == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Withdraw this claim?'),
        content: const Text('It will be removed and the approver will no longer see it.'),
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
      await ErpService.withdrawClaim(e.name);
      messenger.showSnackBar(const SnackBar(content: Text('Claim withdrawn.')));
      if (mounted) Navigator.of(context).pop(true);
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text(err.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final trips = info?.trips ?? const <TripFuel>[];
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'New expense claim' : 'Change claim'),
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
            onPressed: _saving || (_trips.isEmpty && _others.isEmpty) ? null : _submit,
            icon: _saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.send),
            label: Text(_trips.isEmpty && _others.isEmpty
                ? 'Add an expense'
                : '${widget.existing == null ? 'Claim' : 'Save'} ${hsMoney(_total)}'),
          ),
        ),
      ),
      body: info == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)),
            )
          : ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
              const Text('Petrol for trips',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: HsColors.navy)),
              const Padding(
                padding: EdgeInsets.only(top: 2, bottom: 8),
                child: Text('Worked out from the trip km, your vehicle mileage and the petrol price.',
                    style: TextStyle(color: HsColors.textSecondary, fontSize: 13)),
              ),
              if (info.fuelType == null)
                const HsBanner(text: 'Trip petrol can\'t be claimed yet: the office has to set the petrol expense type.')
              else if (trips.isEmpty)
                const Text('No trips in the last two months.', style: TextStyle(color: HsColors.textSecondary)),
              if (info.fuelType != null)
                for (final t in trips)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Material(
                      color: _trips.contains(t.name) ? HsColors.cardHigh : HsColors.card,
                      borderRadius: BorderRadius.circular(14),
                      child: CheckboxListTile(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        value: _trips.contains(t.name),
                        onChanged: !_free(t)
                            ? null
                            : (v) => setState(() => v == true ? _trips.add(t.name) : _trips.remove(t.name)),
                        title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          t.claimedIn != null && !_free(t)
                              ? 'Already claimed in ${t.claimedIn}'
                              : t.amount <= 0
                                  ? 'Set your vehicle mileage to work out the petrol'
                                  : '${_date(t.date)} · ${t.km.toStringAsFixed(1)} km ${t.actual ? 'travelled' : 'planned'} · '
                                      '${t.litres.toStringAsFixed(2)} L',
                          style: TextStyle(color: _free(t) ? null : HsColors.textSecondary),
                        ),
                        secondary: Text(t.amount > 0 ? hsMoney(t.amount) : '–',
                            style: const TextStyle(fontWeight: FontWeight.w800, color: HsColors.navy)),
                        controlAffinity: ListTileControlAffinity.leading,
                      ),
                    ),
                  ),
              const SizedBox(height: 18),
              Row(children: [
                const Expanded(
                  child: Text('Other expenses',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: HsColors.navy)),
                ),
                TextButton.icon(
                  onPressed: info.types.isEmpty ? null : () => _editOther(),
                  icon: const Icon(Icons.add),
                  label: const Text('Add'),
                ),
              ]),
              if (info.types.isEmpty)
                const HsBanner(text: 'No expense types are set up for your company yet. Ask the office.'),
              for (final o in _others)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Material(
                    color: HsColors.card,
                    borderRadius: BorderRadius.circular(14),
                    child: ListTile(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      onTap: () => _editOther(o),
                      leading: const Icon(Icons.receipt_long, color: HsColors.navy),
                      title: Text(o.type),
                      subtitle: Text('${DateFormat('d MMM').format(o.date)}${o.note.isEmpty ? '' : ' · ${o.note}'}'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(hsMoney(o.amount), style: const TextStyle(fontWeight: FontWeight.w800)),
                        IconButton(
                            icon: const Icon(Icons.close), onPressed: () => setState(() => _others.remove(o))),
                      ]),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: _remark,
                decoration: const InputDecoration(labelText: 'Note for the approver (optional)', border: OutlineInputBorder()),
              ),
            ]),
    );
  }
}
