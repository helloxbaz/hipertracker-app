import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Checks GitHub for a newer HiperTracker build and offers to install it.
///
/// Every push to the repo's main branch builds an APK and publishes it as a GitHub
/// release tagged `build-<number>` (see .github/workflows/apk.yml). The build number
/// of the running app is baked in at build time with --dart-define=BUILD_NUMBER.
class UpdateService {
  static const String repo = String.fromEnvironment(
    'UPDATE_REPO',
    defaultValue: 'hipersignerp-dev/Hipersign-traccar-client',
  );
  static const int buildNumber = int.fromEnvironment('BUILD_NUMBER', defaultValue: 0);
  static const String apkName = 'HiperTracker.apk';
  static const _channel = MethodChannel('org.traccar.client/updater');
  static const _checkEvery = Duration(hours: 3);

  static DateTime? _lastCheck;
  static bool _dialogOpen = false;
  static int? _skippedBuild;

  /// Safe to call often (app start, app resume); it only checks GitHub every few hours
  /// unless [force] is set.
  static Future<void> check(BuildContext context, {bool force = false}) async {
    // Builds made without a build number (local/dev builds) never nag.
    if (!Platform.isAndroid || buildNumber == 0 || _dialogOpen) return;
    final now = DateTime.now();
    if (!force && _lastCheck != null && now.difference(_lastCheck!) < _checkEvery) return;
    _lastCheck = now;

    final release = await _latestRelease();
    if (release == null || release.build <= buildNumber) {
      if (force && context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('You have the latest version of HiperTracker.')),
        );
      }
      return;
    }
    if (!force && _skippedBuild == release.build) return;
    if (!context.mounted) return;
    await _showDialog(context, release);
  }

  static Future<_Release?> _latestRelease() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(Uri.parse('https://api.github.com/repos/$repo/releases/latest'));
      request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      request.headers.set(HttpHeaders.userAgentHeader, 'HiperTracker-App');
      final response = await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return null;
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final tag = (json['tag_name'] ?? '').toString();
      final build = int.tryParse(RegExp(r'(\d+)$').firstMatch(tag)?.group(1) ?? '');
      if (build == null) return null;
      final assets = (json['assets'] as List?) ?? const [];
      final apk = assets.cast<Map<String, dynamic>>().firstWhere(
            (a) => (a['name'] ?? '').toString().toLowerCase().endsWith('.apk'),
            orElse: () => const {},
          );
      final url = apk['browser_download_url']?.toString();
      if (url == null || url.isEmpty) return null;
      return _Release(
        build: build,
        name: (json['name'] ?? tag).toString(),
        notes: (json['body'] ?? '').toString().trim(),
        url: url,
      );
    } catch (error) {
      developer.log('Update check failed', error: error);
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> _showDialog(BuildContext context, _Release release) async {
    _dialogOpen = true;
    try {
      final update = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.system_update, size: 36),
          title: const Text('New version available'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(release.name, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                Text('You have build $buildNumber. The new build is ${release.build}.',
                    style: Theme.of(context).textTheme.bodySmall),
                if (release.notes.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text("What's new", style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(release.notes, style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Later')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Update')),
          ],
        ),
      );
      if (update != true) {
        _skippedBuild = release.build;
        return;
      }
      if (!context.mounted) return;
      await _install(context, release);
    } finally {
      _dialogOpen = false;
    }
  }

  static Future<void> _install(BuildContext context, _Release release) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        content: Row(
          children: [
            SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
            SizedBox(width: 16),
            Expanded(child: Text('Downloading update…')),
          ],
        ),
      ),
    ));
    String result;
    try {
      result = await _channel.invokeMethod<String>('install', {'url': release.url, 'name': apkName}) ?? 'error';
    } on PlatformException catch (e) {
      developer.log('Update install failed', error: e);
      result = 'error';
    }
    navigator.pop();
    switch (result) {
      case 'installing':
        break; // Android's installer screen is now open
      case 'permission':
        messenger?.showSnackBar(const SnackBar(
          duration: Duration(seconds: 8),
          content: Text('Allow HiperTracker to install apps, then come back and tap Update again.'),
        ));
        _skippedBuild = null;
        _lastCheck = null;
      default:
        messenger?.showSnackBar(const SnackBar(
          duration: Duration(seconds: 8),
          content: Text('Could not download the update. Check the internet connection and try again.'),
        ));
        _skippedBuild = null;
        _lastCheck = null;
    }
  }
}

class _Release {
  final int build;
  final String name;
  final String notes;
  final String url;

  const _Release({required this.build, required this.name, required this.notes, required this.url});
}
