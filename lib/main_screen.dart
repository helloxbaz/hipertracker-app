import 'dart:developer' as developer;
import 'dart:io';

import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:traccar_client/main.dart';
import 'package:traccar_client/password_service.dart';
import 'package:traccar_client/preferences.dart';
import 'package:traccar_client/trip_card.dart';

import 'app_theme.dart';
import 'erp_service.dart';
import 'geolocation_service.dart';
import 'l10n/app_localizations.dart';
import 'location_guard_service.dart';
import 'update_service.dart';

/// Home tab: greeting, the big Check In / Check Out button, tracking and GPS status, quick actions.
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

  void refresh() => _refreshState();

  // ---------------------------------------------------------------------------------------------

  String get _firstName {
    final name = (ErpService.employeeName ?? '').trim();
    return name.isEmpty ? '' : name.split(' ').first;
  }

  String _timeText(DateTime t) {
    final now = DateTime.now();
    final time = DateFormat.jm().format(t);
    if (t.year == now.year && t.month == now.month && t.day == now.day) return time;
    return '${DateFormat('d MMM').format(t)}, $time';
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
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: HsColors.checkOut),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Check Out'),
            ),
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

  Future<void> _setTracking(bool value) async {
    if (!await PasswordService.authenticate(context) || !mounted) return;
    if (value) {
      var started = false;
      try {
        await GeolocationService.tracker.start();
        started = true;
      } on PlatformException {
        // permission denied or startup error
      }
      if (!started) {
        messengerKey.currentState?.showSnackBar(
          const SnackBar(content: Text('Could not start tracking. Check location permissions.')),
        );
      }
      if (mounted) setState(() => trackingEnabled = started);
    } else {
      await GeolocationService.tracker.stop();
      if (mounted) setState(() => trackingEnabled = false);
    }
  }

  Future<void> _sendNow({bool sos = false}) async {
    try {
      await GeolocationService.tracker.requestPosition(alarm: sos ? 'sos' : null);
      messengerKey.currentState?.showSnackBar(
        SnackBar(content: Text(sos ? 'SOS sent with your location.' : 'Location sent.')),
      );
    } on PlatformException {
      messengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Could not get your location. Check that location is on.')),
      );
    }
  }

  // ---------------------------------------------------------------------------------------------

  Widget _locationWarning() {
    final isOff = locationState == LocationGuardService.off;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: HsPanel(
        color: HsColors.dangerBg,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.location_off, color: HsColors.danger),
            const SizedBox(width: 10),
            Expanded(
              child: Text(isOff ? 'Location is turned off' : 'Location permission removed',
                  style: const TextStyle(color: HsColors.danger, fontSize: 17, fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: 6),
          Text(
            isOff
                ? 'Location must stay on during work. If it stays off, your manager is notified.'
                : 'Set Location to "Allow all the time" for HiperTracker. If it stays off, your manager is notified.',
            style: const TextStyle(color: HsColors.textPrimary),
          ),
          const SizedBox(height: 12),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: HsColors.danger),
            onPressed: () => AppSettings.openAppSettings(
              type: isOff ? AppSettingsType.location : AppSettingsType.settings,
            ),
            child: Text(isOff ? 'Turn on location' : 'Open app settings'),
          ),
        ]),
      ),
    );
  }

  Widget _dutyCard() {
    if (!ErpService.isConnected) {
      return HsPanel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Tracking only', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: HsColors.navy)),
          const SizedBox(height: 4),
          const Text('This phone sends its location without an ERP account. Sign in to Check In and Check Out.',
              style: TextStyle(color: HsColors.textSecondary)),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () async {
              await Preferences.instance.setBool(Preferences.trackingOnly, false);
              ErpService.changes.value++;
            },
            icon: const Icon(Icons.login),
            label: const Text('Sign in'),
          ),
        ]),
      );
    }
    final onDuty = ErpService.onDuty;
    final since = ErpService.dutySince;
    return HsPanel(
      color: onDuty ? HsColors.onDutyBg : HsColors.card,
      padding: const EdgeInsets.all(18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: onDuty ? HsColors.onDuty : HsColors.textSecondary,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(onDuty ? 'CHECKED IN' : 'CHECKED OUT',
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: .5)),
          ),
          const Spacer(),
          if (since != null)
            Text(_timeText(since), style: const TextStyle(color: HsColors.textSecondary, fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 12),
        Text(
          onDuty ? 'You are on duty' : 'Ready to start?',
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: HsColors.navy),
        ),
        const SizedBox(height: 2),
        Text(
          ErpService.dutyMode
              ? (onDuty ? 'Your location is shared with your team until you check out.'
                  : 'Your location is tracked only while you are checked in.')
              : 'Your attendance is saved in ERP with your location.',
          style: const TextStyle(color: HsColors.textSecondary),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: onDuty ? HsColors.checkOut : HsColors.onDuty,
            minimumSize: const Size.fromHeight(58),
            textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          onPressed: _dutyBusy ? null : () => _checkInOut(!onDuty),
          icon: _dutyBusy
              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
              : Icon(onDuty ? Icons.logout : Icons.login),
          label: Text(_dutyBusy ? 'Getting your location…' : (onDuty ? 'Check Out' : 'Check In')),
        ),
      ]),
    );
  }

  Widget _statusTile({required IconData icon, required String title, required String value, required bool good}) {
    return Expanded(
      child: HsPanel(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: good ? HsColors.onDuty : HsColors.textSecondary),
          const SizedBox(height: 8),
          Text(title, style: const TextStyle(color: HsColors.textSecondary, fontSize: 13)),
          Text(value, style: TextStyle(fontWeight: FontWeight.w700, color: good ? HsColors.onDuty : HsColors.textPrimary)),
        ]),
      ),
    );
  }

  Widget _trackingSwitch() {
    // with check in / check out the duty state starts and stops tracking; otherwise a (password-protected) switch
    if (ErpService.isConnected && ErpService.dutyMode) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: HsPanel(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: SwitchListTile(
          title: Text(AppLocalizations.of(context)!.trackingLabel, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(trackingEnabled ? 'Sending your location' : 'Not sending your location'),
          value: trackingEnabled,
          onChanged: _setTracking,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final gpsOn = locationState == LocationGuardService.on;
    final greeting = _firstName.isEmpty ? 'HiperTracker' : 'Hi $_firstName';
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(greeting, style: const TextStyle(fontWeight: FontWeight.w800)),
          Text(DateFormat('EEEE, d MMMM').format(DateTime.now()),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w400, color: HsColors.textSecondary)),
        ]),
        toolbarHeight: 68,
      ),
      body: RefreshIndicator(
        onRefresh: () => _refreshState(syncErp: true),
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          if (!gpsOn) _locationWarning(),
          _dutyCard(),
          if (ErpService.isConnected) const TodayTripCard(),
          const SizedBox(height: 12),
          Row(children: [
            _statusTile(
              icon: trackingEnabled ? Icons.gps_fixed : Icons.gps_not_fixed,
              title: 'Tracking',
              value: trackingEnabled ? 'On' : 'Off',
              good: trackingEnabled,
            ),
            const SizedBox(width: 12),
            _statusTile(
              icon: gpsOn ? Icons.location_on : Icons.location_off,
              title: 'Location',
              value: gpsOn ? 'On' : (locationState == LocationGuardService.off ? 'Off' : 'No permission'),
              good: gpsOn,
            ),
          ]),
          _trackingSwitch(),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _sendNow(),
                icon: const Icon(Icons.my_location),
                label: const Text('Send location'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: HsColors.danger,
                  side: const BorderSide(color: HsColors.dangerBg, width: 1.5),
                ),
                onPressed: () => _sendNow(sos: true),
                icon: const Icon(Icons.sos),
                label: const Text('SOS'),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          Row(children: [
            const Icon(Icons.smartphone, size: 18, color: HsColors.textSecondary),
            const SizedBox(width: 6),
            Text('Phone ID ${Preferences.instance.getString(Preferences.id) ?? ''}',
                style: const TextStyle(color: HsColors.textSecondary)),
          ]),
          if (Platform.isAndroid) ...[
            const SizedBox(height: 8),
            Text(AppLocalizations.of(context)!.disclosureMessage,
                style: const TextStyle(color: HsColors.textSecondary, fontSize: 12)),
          ],
        ]),
      ),
    );
  }
}
