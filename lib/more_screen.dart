import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'erp_service.dart';
import 'log_screen.dart';
import 'password_service.dart';
import 'preferences.dart';
import 'settings_screen.dart';
import 'status_screen.dart';
import 'update_service.dart';

/// More tab, laid out like the Hipersign mobile app: profile card, then settings rows and sign out.
class MoreScreen extends StatefulWidget {
  const MoreScreen({super.key});

  @override
  State<MoreScreen> createState() => _MoreScreenState();
}

class _MoreScreenState extends State<MoreScreen> {
  @override
  void initState() {
    super.initState();
    ErpService.changes.addListener(_changed);
  }

  @override
  void dispose() {
    ErpService.changes.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _open(Widget screen, {bool protected = false}) async {
    if (protected && !await PasswordService.authenticate(context)) return;
    if (!mounted) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    if (mounted) setState(() {});
  }

  Future<void> _signOut() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out?'),
        content: Text(ErpService.onDuty
            ? 'You are checked in. Signing out stops tracking; check out first if your day is over.'
            : 'You can sign in again any time.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sign out')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (!await PasswordService.authenticate(context)) return;
    await ErpService.logout();
  }

  /// Tracking-only phone: go to the sign-in screen (tracking keeps running until someone signs in).
  Future<void> _signIn() async {
    await Preferences.instance.setBool(Preferences.trackingOnly, false);
    ErpService.changes.value++;
  }

  @override
  Widget build(BuildContext context) {
    final connected = ErpService.isConnected;
    final name = connected ? (ErpService.employeeName ?? ErpService.user ?? '') : 'Tracking only';
    final sub = connected ? (ErpService.user ?? '') : 'Not signed in';
    final server = Preferences.displayServerUrl(Preferences.instance.getString(Preferences.url));
    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        HsPanel(
          child: Row(children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: HsColors.accent,
              foregroundColor: HsColors.onAccent,
              child: connected && name.isNotEmpty
                  ? Text(name[0].toUpperCase(), style: const TextStyle(fontSize: 20))
                  : const Icon(Icons.smartphone),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                Text(sub, style: const TextStyle(color: HsColors.textSecondary, fontSize: 13)),
                Text('Phone ID ${Preferences.instance.getString(Preferences.id) ?? ''}',
                    style: const TextStyle(color: HsColors.textSecondary, fontSize: 13)),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 16),
        if (connected)
          HsTile(
            icon: Icons.history,
            title: 'Activity log',
            subtitle: 'Trips, stops, check ins, location off',
            onTap: () => _open(const LogScreen()),
          ),
        HsTile(
          icon: Icons.tune,
          title: 'Tracking settings',
          subtitle: server,
          onTap: () => _open(const SettingsScreen(), protected: true),
        ),
        HsTile(
          icon: Icons.receipt_long_outlined,
          title: 'Phone status',
          subtitle: 'What the phone has sent',
          onTap: () => _open(const StatusScreen()),
        ),
        HsTile(
          icon: Icons.system_update_outlined,
          title: 'Check for updates',
          subtitle: UpdateService.buildNumber > 0 ? 'Version ${UpdateService.buildNumber}' : null,
          onTap: () => UpdateService.check(context, force: true),
        ),
        const SizedBox(height: 8),
        if (connected)
          HsTile(icon: Icons.logout, title: 'Sign out', danger: true, onTap: _signOut)
        else
          HsTile(icon: Icons.login, title: 'Sign in with ERP account', onTap: _signIn),
      ]),
    );
  }
}
