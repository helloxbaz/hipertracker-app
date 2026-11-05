import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'erp_service.dart';
import 'geolocation_service.dart';
import 'preferences.dart';
import 'qr_code_screen.dart';

/// First screen, laid out like the Hipersign mobile app: sign in with the company ERP account.
/// Phones without an ERP account can still be used for tracking only (server address + ID, like Traccar).
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _server = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;
  bool _showServer = false;
  bool _obscure = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _server.text = ErpService.url ?? ErpService.defaultUrl;
    _user.text = ErpService.user ?? '';
  }

  @override
  void dispose() {
    _server.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  String get _host => Uri.tryParse(ErpService.normalizeUrl(_server.text))?.host ?? 'Server';

  Future<void> _submit() async {
    if (_user.text.trim().isEmpty || _pass.text.isEmpty) {
      setState(() => _error = 'Enter your email and password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ErpService.login(_server.text, _user.text.trim(), _pass.text);
      await Preferences.instance.setBool(Preferences.trackingOnly, false);
      ErpService.changes.value++;
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _trackingOnly() async {
    final server = TextEditingController(
      text: Preferences.displayServerUrl(Preferences.instance.getString(Preferences.url)),
    );
    final id = Preferences.instance.getString(Preferences.id) ?? '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Tracking only'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('This phone sends its location without an ERP account. '
              'Check In / Check Out needs an account.', style: TextStyle(color: HsColors.textSecondary)),
          const SizedBox(height: 16),
          TextField(
            controller: server,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: 'Server address', prefixIcon: Icon(Icons.dns_outlined)),
          ),
          const SizedBox(height: 12),
          Text('Phone ID: $id', style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          const Text('Your manager links this ID to you in HiperTracker.',
              style: TextStyle(color: HsColors.textSecondary, fontSize: 13)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Continue')),
        ],
      ),
    );
    if (ok != true) return;
    final url = Preferences.normalizeServerUrl(server.text.isEmpty ? ErpService.defaultUrl : server.text);
    await Preferences.instance.setString(Preferences.url, url);
    await Preferences.instance.setBool(Preferences.trackingOnly, true);
    await GeolocationService.tracker.setConfig(Preferences.buildConfig());
    ErpService.changes.value++;
  }

  /// The device's setup QR (HiperTracker → Devices & People) sets the server, ID and key in one go.
  Future<void> _scanSetupQr() async {
    String setup() => '${Preferences.instance.getString(Preferences.url)}|${Preferences.instance.getString(Preferences.id)}';
    final before = setup();
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const QrCodeScreen()));
    if (setup() == before) return; // nothing scanned
    await Preferences.instance.setBool(Preferences.trackingOnly, true);
    ErpService.changes.value++;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AutofillGroup(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const SizedBox(height: 24),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: ClipRRect(
                      borderRadius: BorderRadius.all(Radius.circular(16)),
                      child: Image(image: AssetImage('assets/branding/logo.png'), width: 72, height: 72),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('HiperTracker',
                      style: TextStyle(fontSize: 34, fontWeight: FontWeight.w800, color: HsColors.accent)),
                  const SizedBox(height: 6),
                  const Text('Sign in with your company ERP account', style: TextStyle(color: HsColors.textSecondary)),
                  const SizedBox(height: 28),
                  TextField(
                    controller: _user,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.username, AutofillHints.email],
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.person_outline)),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _pass,
                    obscureText: _obscure,
                    autofillHints: const [AutofillHints.password],
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      labelText: 'Password',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        tooltip: _obscure ? 'Show password' : 'Hide password',
                        icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_showServer)
                    TextField(
                      controller: _server,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(labelText: 'Server address', prefixIcon: Icon(Icons.dns_outlined)),
                    )
                  else
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => setState(() => _showServer = true),
                        icon: const Icon(Icons.dns_outlined, size: 18),
                        label: Text(_host),
                      ),
                    ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    HsBanner(text: _error!, error: true),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                        : const Text('Sign in'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _busy ? null : _trackingOnly,
                    child: const Text('Use without an account (tracking only)'),
                  ),
                  TextButton.icon(
                    onPressed: _busy ? null : _scanSetupQr,
                    icon: const Icon(Icons.qr_code_scanner, size: 18),
                    label: const Text('Scan setup QR from HiperTracker'),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
