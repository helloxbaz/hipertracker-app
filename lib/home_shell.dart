import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'main.dart';
import 'main_screen.dart';
import 'more_screen.dart';
import 'my_day_screen.dart';
import 'requests_screen.dart';

/// Bottom-bar shell, the same pattern as the Hipersign mobile app: Home, My Day, (+), Requests, More.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      MainScreen(key: mainScreenKey),
      const MyDayScreen(),
      const RequestsScreen(),
      const MoreScreen(),
    ];
    // bar: Home, My Day, [+], Requests, More
    final tabs = <(IconData, String, int)>[
      (Icons.home_outlined, 'Home', 0),
      (Icons.event_note_outlined, 'My Day', 1),
      (Icons.inbox_outlined, 'Requests', 2),
      (Icons.more_horiz, 'More', 3),
    ];
    Widget nav((IconData, String, int) t) =>
        _NavItem(icon: t.$1, label: t.$2, selected: _tab == t.$3, onTap: () => setState(() => _tab = t.$3));
    return Scaffold(
      body: IndexedStack(index: _tab, children: pages),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: FloatingActionButton(
        tooltip: 'Plan a trip, leave, expense',
        backgroundColor: HsColors.accent,
        foregroundColor: HsColors.onAccent,
        shape: const CircleBorder(),
        onPressed: () => showQuickAdd(context),
        child: const Icon(Icons.add, size: 30),
      ),
      bottomNavigationBar: BottomAppBar(
        color: HsColors.background,
        shape: const CircularNotchedRectangle(),
        notchMargin: 8,
        padding: EdgeInsets.zero,
        height: 68,
        child: Row(children: [
          nav(tabs[0]),
          nav(tabs[1]),
          const Expanded(child: SizedBox()),
          nav(tabs[2]),
          nav(tabs[3]),
        ]),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.icon, required this.label, required this.selected, required this.onTap});

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? HsColors.accent : HsColors.textSecondary;
    return Expanded(
      child: Semantics(
        selected: selected,
        button: true,
        label: label,
        child: InkWell(
          onTap: onTap,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, color: color),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 11, color: color, fontWeight: selected ? FontWeight.w700 : null)),
          ]),
        ),
      ),
    );
  }
}
