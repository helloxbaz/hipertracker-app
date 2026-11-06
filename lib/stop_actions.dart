import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_theme.dart';
import 'erp_service.dart';

const stopColors = {
  'Pending': HsColors.textSecondary,
  'Reached': Color(0xFFF59E0B),
  'Left': HsColors.onDuty,
  'Skipped': Color(0xFF9CA3AF),
};

String stopStatusLabel(String s) => s == 'Left' ? 'Done' : s;

/// Numbered circle for a stop, coloured by how far it has got.
class StopBadge extends StatelessWidget {
  const StopBadge({super.key, required this.number, required this.status, this.highlight = false});
  final int number;
  final String status;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: stopColors[status] ?? HsColors.textSecondary,
        shape: BoxShape.circle,
        border: Border.all(color: highlight ? HsColors.blue : Colors.white, width: highlight ? 3 : 2),
        boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 4, offset: Offset(0, 1))],
      ),
      child: status == 'Left'
          ? const Icon(Icons.check, size: 16, color: Colors.white)
          : Text('$number', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
    );
  }
}

Future<void> _open(BuildContext context, Uri uri, String failure) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
  } catch (_) {}
  messenger.showSnackBar(SnackBar(content: Text(failure)));
}

Future<void> callStop(BuildContext context, PlanStop s) =>
    _open(context, Uri(scheme: 'tel', path: s.phone!.replaceAll(RegExp(r'[^0-9+]'), '')), 'Could not start a call');

/// Details of one stop with Navigate and Call.
void showStopSheet(BuildContext context, PlanStop s, int number, {VoidCallback? onNavigate}) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            SizedBox(width: 30, height: 30, child: StopBadge(number: number, status: s.status)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: HsColors.navy)),
                if (s.type != null) Text(s.type!, style: const TextStyle(color: HsColors.textSecondary)),
              ]),
            ),
            Text(stopStatusLabel(s.status), style: const TextStyle(fontWeight: FontWeight.w600)),
          ]),
          const SizedBox(height: 12),
          if (s.address != null) _line(Icons.place_outlined, s.address!),
          if (s.planned != null) _line(Icons.schedule, 'Planned ${s.planned}'),
          if (s.arrived != null) _line(Icons.login, 'Reached ${s.arrived}${s.left != null ? ' · left ${s.left}' : ''}'),
          if (s.task != null && s.task!.trim().isNotEmpty) _line(Icons.assignment_outlined, s.task!.trim()),
          const SizedBox(height: 12),
          Row(children: [
            if (s.phone != null) ...[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => callStop(ctx, s),
                  icon: const Icon(Icons.call),
                  label: const Text('Call'),
                ),
              ),
              const SizedBox(width: 10),
            ],
            if (onNavigate != null)
              Expanded(
                child: FilledButton.icon(
                  onPressed: s.hasLocation
                      ? () {
                          Navigator.of(ctx).pop();
                          onNavigate();
                        }
                      : null,
                  icon: const Icon(Icons.navigation),
                  label: const Text('Start trip'),
                ),
              ),
          ]),
        ]),
      ),
    ),
  );
}

Widget _line(IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: HsColors.textSecondary),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ]),
    );
