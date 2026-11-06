import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'erp_service.dart';
import 'expenses_screen.dart';
import 'leave_screen.dart';
import 'plan_trip_screen.dart';

/// Requests tab: my leave and my expense claims in one place. New ones come from the + button.
class RequestsScreen extends StatelessWidget {
  const RequestsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    if (!ErpService.isConnected) {
      return Scaffold(
        appBar: AppBar(title: const Text('Requests')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(28),
            child: Text('Sign in with your ERP account to apply for leave and claim expenses.',
                textAlign: TextAlign.center, style: TextStyle(color: HsColors.textSecondary)),
          ),
        ),
      );
    }
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Requests'),
          bottom: const TabBar(tabs: [
            Tab(icon: Icon(Icons.event_busy), text: 'Leave'),
            Tab(icon: Icon(Icons.receipt_long), text: 'Expenses'),
          ]),
        ),
        body: const TabBarView(children: [
          LeaveScreen(embedded: true),
          ExpensesScreen(embedded: true),
        ]),
      ),
    );
  }
}

/// The + button: plan a trip, apply for leave, claim expenses or a trip's fuel.
Future<void> showQuickAdd(BuildContext context) async {
  if (!ErpService.isConnected) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Sign in with your ERP account first (More > Sign in).')));
    return;
  }
  Widget item(BuildContext sheet, IconData icon, Color color, String title, String subtitle, Widget Function() screen) =>
      ListTile(
        leading: CircleAvatar(backgroundColor: color, child: Icon(icon, color: Colors.white)),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(subtitle),
        onTap: () {
          Navigator.pop(sheet);
          Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen()));
        },
      );
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        item(sheet, Icons.add_road, HsColors.navy, 'Plan a trip', 'Pick customers, best order and route',
            () => const PlanTripScreen()),
        item(sheet, Icons.event_busy, const Color(0xFF7C3AED), 'Apply for leave', 'Days or half a day',
            () => const ApplyLeaveScreen()),
        item(sheet, Icons.receipt_long, HsColors.onDuty, 'Expense claim', 'Trip fuel fills in by itself, plus other expenses',
            () => const NewClaimScreen()),
        const SizedBox(height: 8),
      ]),
    ),
  );
}
