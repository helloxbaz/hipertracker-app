import 'package:flutter/material.dart';

import 'erp_service.dart';
import 'preferences.dart';

/// Log in to Hipersign ERP with the worker's ERP username and password.
class ErpLoginScreen extends StatefulWidget {
  const ErpLoginScreen({super.key});

  @override
  State<ErpLoginScreen> createState() => _ErpLoginScreenState();
}

class _ErpLoginScreenState extends State<ErpLoginScreen> {
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _showPassword = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _url.text = ErpService.url ?? ErpService.defaultUrl;
    _user.text = ErpService.user ?? '';
  }

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ErpService.login(_url.text, _user.text, _password.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connected as ${ErpService.employeeName ?? _user.text}')),
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _logout() async {
    if (ErpService.onDuty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('You are checked in'),
          content: const Text('Logging out stops tracking but does not check you out in the ERP. Check out first?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Log out anyway')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await ErpService.logout();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final connected = ErpService.isConnected;
    return Scaffold(
      appBar: AppBar(title: const Text('Hipersign ERP')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (connected) ...[
            Card(
              child: ListTile(
                leading: const Icon(Icons.verified_user, color: Colors.green),
                title: Text(ErpService.employeeName ?? ErpService.user ?? ''),
                subtitle: Text(
                  '${ErpService.user ?? ''}\n${ErpService.url ?? ''}\n'
                  'Tracker ID ${Preferences.instance.getString(Preferences.id) ?? ''}',
                ),
                isThreeLine: true,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _busy
                  ? null
                  : () async {
                      setState(() => _busy = true);
                      try {
                        await ErpService.refreshConfig();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Settings updated from the ERP')));
                        }
                      } catch (e) {
                        if (mounted) setState(() => _error = e.toString());
                      } finally {
                        if (mounted) setState(() => _busy = false);
                      }
                    },
              icon: const Icon(Icons.sync),
              label: const Text('Update settings from ERP'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(onPressed: _busy ? null : _logout, icon: const Icon(Icons.logout), label: const Text('Log out')),
          ] else ...[
            Text(
              'Log in with your Hipersign ERP account to check in and out. Tracking runs while you are checked in.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'ERP address', border: OutlineInputBorder(), prefixIcon: Icon(Icons.public)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _user,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Username or email', border: OutlineInputBorder(), prefixIcon: Icon(Icons.person)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: !_showPassword,
              onSubmitted: (_) => _busy ? null : _login(),
              decoration: InputDecoration(
                labelText: 'Password',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.lock),
                suffixIcon: IconButton(
                  icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _showPassword = !_showPassword),
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _login,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              child: _busy
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                  : const Text('Log in'),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
    );
  }
}
