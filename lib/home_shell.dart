import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'main.dart';
import 'main_screen.dart';
import 'more_screen.dart';
import 'my_day_screen.dart';

/// Bottom-bar shell, the same pattern as the Hipersign mobile app: Home, My Day, More.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final tabs = <(IconData, String, Widget)>[
      (Icons.home_outlined, 'Home', MainScreen(key: mainScreenKey)),
      (Icons.event_note_outlined, 'My Day', const MyDayScreen()),
      (Icons.more_horiz, 'More', const MoreScreen()),
    ];
    return Scaffold(
      body: IndexedStack(index: _tab, children: [for (final t in tabs) t.$3]),
      bottomNavigationBar: BottomAppBar(
        color: HsColors.background,
        padding: EdgeInsets.zero,
        height: 68,
        child: Row(children: [
          for (var i = 0; i < tabs.length; i++)
            _NavItem(icon: tabs[i].$1, label: tabs[i].$2, selected: _tab == i, onTap: () => setState(() => _tab = i)),
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
