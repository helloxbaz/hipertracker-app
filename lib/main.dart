import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app_links/app_links.dart';
import 'package:traccar_client/password_service.dart';
import 'package:traccar_client/push_service.dart';
import 'package:traccar_client/quick_actions.dart';
import 'package:traccar_client/update_service.dart';

import 'app_theme.dart';
import 'configuration_service.dart';
import 'erp_service.dart';
import 'geolocation_service.dart';
import 'home_shell.dart';
import 'l10n/app_localizations.dart';
import 'main_screen.dart';
import 'managed_config_service.dart';
import 'preferences.dart';
import 'sign_in_screen.dart';

final messengerKey = GlobalKey<ScaffoldMessengerState>();
final navigatorKey = GlobalKey<NavigatorState>();
final mainScreenKey = GlobalKey<MainScreenState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;
  PlatformDispatcher.instance.onError = (error, stack) {
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    return true;
  };
  // a screen that fails shows what went wrong (instead of a plain grey screen), so it can be reported
  ErrorWidget.builder = (details) => Material(
        color: const Color(0xFFFDECEC),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              'Something went wrong on this screen. Please send a screenshot to your admin.\n\n${details.exceptionAsString()}',
              style: const TextStyle(color: Color(0xFFC62828), fontSize: 14),
            ),
          ),
        ),
      );
  await Preferences.init();
  await GeolocationService.tracker.init(Preferences.buildConfig());
  await PasswordService.migrate();
  await PushService.init();
  await ManagedConfigService.init();
  runApp(const MainApp());
}

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _initLinks();
      // The store "rate this app" prompt is skipped: HiperTracker is installed from GitHub, not a store.
      final updateContext = navigatorKey.currentContext;
      if (updateContext != null && updateContext.mounted) {
        await UpdateService.check(updateContext);
      }
    });
  }

  Future<void> _initLinks() async {
    AppLinks().uriLinkStream.listen(_handleUri);
  }

  Future<void> _handleUri(Uri uri) async {
    final context = navigatorKey.currentState?.overlay?.context;
    if (Preferences.instance.getString(Preferences.password) != null) {
      if (context == null || !context.mounted) return;
      if (!await PasswordService.authenticate(context) || !context.mounted) return;
    }
    if (uri.host == 'action') {
      try {
        switch (uri.pathSegments.firstOrNull) {
          case 'start':
            await GeolocationService.tracker.start();
          case 'stop':
            await GeolocationService.tracker.stop();
        }
      } on PlatformException {
        // permission denied or startup error
      }
      return;
    }
    if (context == null || !context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(AppLocalizations.of(context)!.configurationMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(AppLocalizations.of(context)!.cancelButton),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppLocalizations.of(context)!.okButton),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ConfigurationService.applyUri(uri);
      // a setup link makes the phone a tracker even before anyone signs in
      if (!ErpService.isConnected) await Preferences.instance.setBool(Preferences.trackingOnly, true);
      ErpService.changes.value++;
      mainScreenKey.currentState?.refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      scaffoldMessengerKey: messengerKey,
      navigatorKey: navigatorKey,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      title: 'HiperTracker',
      // same light Hipersign theme as the Hipersign mobile app
      theme: buildTheme(),
      home: const Stack(
        children: [
          QuickActionsInitializer(),
          _Root(),
        ],
      ),
    );
  }
}

/// Signed in to the ERP (or set up for tracking only): the app. Otherwise: the sign-in screen.
class _Root extends StatefulWidget {
  const _Root();

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  @override
  void initState() {
    super.initState();
    ErpService.changes.addListener(_changed);
    _keepTrackingOnlyPhones();
  }

  @override
  void dispose() {
    ErpService.changes.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Phones that were already tracking without an ERP login before this version stay that way.
  Future<void> _keepTrackingOnlyPhones() async {
    final p = Preferences.instance;
    if (ErpService.isConnected || p.getBool(Preferences.trackingOnly) != null) return;
    if (await GeolocationService.tracker.isTracking()) {
      await p.setBool(Preferences.trackingOnly, true);
      _changed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final inApp = ErpService.isConnected || (Preferences.instance.getBool(Preferences.trackingOnly) ?? false);
    return inApp ? const HomeShell() : const SignInScreen();
  }
}
