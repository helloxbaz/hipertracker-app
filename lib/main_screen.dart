import 'dart:developer' as developer;
import 'dart:io';

import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:traccar_client/main.dart';
import 'package:traccar_client/password_service.dart';
import 'package:traccar_client/preferences.dart';

import 'geolocation_service.dart';
import 'erp_login_screen.dart';
import 'erp_service.dart';
import 'location_guard_service.dart';
import 'update_service.dart';
import 'l10n/app_localizations.dart';
import 'settings_screen.dart';
import 'status_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => MainScreenState();
}

class MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  bool trackingEnabled = false;
  String locationState = LocationGuardService.on;
  bool _dutyBusy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ErpService.changes.addListener(_onErpChanged);
    _refreshState(syncErp: true);
  }

  @override
  void dispose() {
    ErpService.changes.removeListener(_onErpChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onErpChanged() {
    if (mounted) _refreshState();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshState(syncErp: true);
      UpdateService.check(context);
    }
  }

  Future<void> _refreshState({bool syncErp = false}) async {
    if (syncErp && ErpService.isConnected) {
      // pick up check-in state and alarm settings changed in the ERP (quietly; offline is fine)
      try {
        await ErpService.refreshConfig();
      } catch (e) {
        developer.log('ERP refresh failed', error: e);
      }
    }
    final tracking = await GeolocationService.tracker.isTracking();
    final location = await LocationGuardService.check();
    if (!mounted) return;
    setState(() {
      trackingEnabled = tracking;
      locationState = location;
    });
  }

  void refresh() => setState(() {});

  Widget _buildLocationWarningCard() {
    final colors = Theme.of(context).colorScheme;
    final isOff = locationState == LocationGuardService.off;
    return Card(
      color: colors.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.location_off, color: colors.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isOff ? 'Location is turned off' : 'Location permission removed',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(color: colors.onErrorContainer),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              isOff
                  ? 'Location must stay on during work. If it stays off, your manager is notified.'
                  : 'Set Location to "Allow all the time" for this app. If it stays off, your manager is notified.',
              style: TextStyle(color: colors.onErrorContainer),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => AppSettings.openAppSettings(
                type: isOff ? AppSettingsType.location : AppSettingsType.settings,
              ),
              child: Text(isOff ? 'Turn on location' : 'Open app settings'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openErp() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const ErpLoginScreen()));
    if (mounted) _refreshState();
  }

  Future<void> _checkInOut(bool checkIn) async {
    if (!checkIn) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Check out?'),
          content: const Text('Tracking stops when you check out.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Check Out')),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _dutyBusy = true);
    try {
      final message = await ErpService.checkInOut(checkIn);
      messengerKey.currentState?.showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      messengerKey.currentState?.showSnackBar(
        SnackBar(content: Text(e.toString()), duration: const Duration(seconds: 6)),
      );
    } finally {
      if (mounted) setState(() => _dutyBusy = false);
      await _refreshState();
    }
  }

  String _sinceText(DateTime since) {
    final now = DateTime.now();
    final time = TimeOfDay.fromDateTime(since).format(context);
    if (since.year == now.year && since.month == now.month && since.day == now.day) return time;
    return '${since.day}/${since.month} $time';
  }

  Widget _buildAttendanceCard() {
    final colors = Theme.of(context).colorScheme;
    if (!ErpService.isConnected) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Check In / Check Out', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 6),
              const Text('Log in with your Hipersign ERP account to check in and out.'),
              const SizedBox(height: 12),
              FilledButton.icon(onPressed: _openErp, icon: const Icon(Icons.login), label: const Text('Log in to ERP')),
            ],
          ),
        ),
      );
    }
    final onDuty = ErpService.onDuty;
    final since = ErpService.dutySince;
    final green = Colors.green.shade700;
    final red = Colors.red.shade700;
    return Card(
      color: onDuty ? Color.alphaBlend(green.withValues(alpha: 0.08), colors.surface) : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: (onDuty ? green : colors.outline).withValues(alpha: 0.15),
                  child: Icon(onDuty ? Icons.work : Icons.work_off, color: onDuty ? green : colors.outline),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(ErpService.employeeName ?? ErpService.user ?? '', style: Theme.of(context).textTheme.titleMedium),
                      Text(
                        onDuty
                            ? 'Checked in${since != null ? ' at ${_sinceText(since)}' : ''}'
                            : 'Checked out${since != null ? ' at ${_sinceText(since)}' : ''}',
                        style: TextStyle(color: onDuty ? green : colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                IconButton(icon: const Icon(Icons.manage_accounts), tooltip: 'ERP account', onPressed: _openErp),
              ],
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: onDuty ? red : green,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(56),
                textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              onPressed: _dutyBusy ? null : () => _checkInOut(!onDuty),
              icon: _dutyBusy
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                  : Icon(onDuty ? Icons.logout : Icons.login),
              label: Text(_dutyBusy ? 'Getting your location…' : (onDuty ? 'Check Out' : 'Check In')),
            ),
            if (ErpService.dutyMode) ...[
              const SizedBox(height: 8),
              Text(
                'Your location is tracked only while you are checked in.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTrackingCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(AppLocalizations.of(context)!.trackingTitle),
              titleTextStyle: Theme.of(context).textTheme.headlineMedium,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(AppLocalizations.of(context)!.idLabel),
              subtitle: Text(Preferences.instance.getString(Preferences.id) ?? ''),
            ),
            if (Platform.isAndroid) ...[
              Text(
                AppLocalizations.of(context)!.disclosureMessage,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
            ],
            if (ErpService.isConnected && ErpService.dutyMode)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(AppLocalizations.of(context)!.trackingLabel),
                subtitle: Text(trackingEnabled ? 'On (checked in)' : 'Off. Starts when you check in.'),
                trailing: Icon(
                  trackingEnabled ? Icons.gps_fixed : Icons.gps_off,
                  color: trackingEnabled ? Colors.green.shade700 : Theme.of(context).colorScheme.outline,
                ),
              )
            else
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(AppLocalizations.of(context)!.trackingLabel),
              value: trackingEnabled,
              onChanged: (bool value) async {
                if (await PasswordService.authenticate(context) && mounted) {
                  if (value) {
                    developer.log('tracking_toggle_start');
                    var started = false;
                    try {
                      await GeolocationService.tracker.start();
                      started = true;
                    } on PlatformException {
                      // permission denied or startup error
                    }
                    if (!mounted) return;
                    if (!started) {
                      messengerKey.currentState?.showSnackBar(
                        const SnackBar(
                          content: Text('Failed to start tracking. Check location permissions.'),
                          duration: Duration(seconds: 4),
                        ),
                      );
                    }
                    setState(() => trackingEnabled = started);
                  } else {
                    developer.log('tracking_toggle_stop');
                    await GeolocationService.tracker.stop();
                    if (mounted) setState(() => trackingEnabled = false);
                  }
                }
              },
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: () async {
                    try {
                      await GeolocationService.tracker.requestPosition();
                    } on PlatformException {
                      // permission denied or location error
                    }
                  },
                  child: Text(AppLocalizations.of(context)!.locationButton),
                ),
                FilledButton.tonal(
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.errorContainer,
                    foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                  onPressed: () async {
                    try {
                      await GeolocationService.tracker.requestPosition(alarm: 'sos');
                    } on PlatformException {
                      // permission denied or location error
                    }
                  },
                  child: Text(AppLocalizations.of(context)!.sosAction),
                ),
                FilledButton.tonal(
                  onPressed: () {
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const StatusScreen()));
                  },
                  child: Text(AppLocalizations.of(context)!.statusButton),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(AppLocalizations.of(context)!.settingsTitle),
              titleTextStyle: Theme.of(context).textTheme.headlineMedium,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(AppLocalizations.of(context)!.urlLabel),
              subtitle: Text(Preferences.instance.getString(Preferences.url) ?? ''),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: () async {
                    if (await PasswordService.authenticate(context) && mounted) {
                      await Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
                      setState(() {});
                    }
                  },
                  child: Text(AppLocalizations.of(context)!.settingsButton),
                ),
              ],
            ),
          ]
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('HiperTracker'),
        actions: [
          IconButton(
            icon: const Icon(Icons.system_update),
            tooltip: 'Check for updates',
            onPressed: () => UpdateService.check(context, force: true),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            if (locationState != LocationGuardService.on) ...[
              _buildLocationWarningCard(),
              const SizedBox(height: 16),
            ],
            _buildAttendanceCard(),
            const SizedBox(height: 16),
            _buildTrackingCard(),
            const SizedBox(height: 16),
            _buildSettingsCard(),
          ],
        ),
      ),
    );
  }
}
