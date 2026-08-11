import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../core/sync/odoo_endpoint.dart';

/// Point this till at an Odoo server.
///
/// For a local, single-operator test. On a real fleet the till talks to a backend
/// that holds the one shared credential, and this screen would only carry the
/// backend URL and a device token, never an Odoo password. The warning below says
/// so on the screen itself, not just in the docs.
class ServerSettingsScreen extends StatefulWidget {
  const ServerSettingsScreen({
    super.key,
    required this.store,
    required this.onSaved,
  });

  final OdooEndpointStore store;

  /// Called with the saved endpoint so the app can (re)wire the sender live.
  final void Function(OdooEndpoint) onSaved;

  @override
  State<ServerSettingsScreen> createState() => _ServerSettingsScreenState();
}

class _ServerSettingsScreenState extends State<ServerSettingsScreen> {
  late final TextEditingController _url;
  late final TextEditingController _db;
  late final TextEditingController _login;
  late final TextEditingController _pass;
  String? _message;

  @override
  void initState() {
    super.initState();
    final e = widget.store.load();
    _url = TextEditingController(text: e?.baseUrl ?? '');
    _db = TextEditingController(text: e?.db ?? '');
    _login = TextEditingController(text: e?.login ?? '');
    _pass = TextEditingController(text: e?.password ?? '');
  }

  @override
  void dispose() {
    _url.dispose();
    _db.dispose();
    _login.dispose();
    _pass.dispose();
    super.dispose();
  }

  void _save() {
    final e = OdooEndpoint(
      baseUrl: _url.text.trim(),
      db: _db.text.trim(),
      login: _login.text.trim(),
      password: _pass.text.isEmpty ? null : _pass.text,
    );
    if (!e.isComplete) {
      setState(() => _message = tr(context, 'URL, database and login are all required.'));
      return;
    }
    widget.store.save(e);
    widget.onSaved(e);
    setState(() => _message = tr(context, 'Saved. Queued sales will sync on the next attempt.'));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Server settings'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            key: const Key('local-test-warning'),
            color: Colors.amber.shade100,
            padding: const EdgeInsets.all(12),
            child: Text(
              tr(context,
                  'For local testing. A live fleet points at a backend and never stores '
                  'an Odoo password on the till.'),
            ),
          ),
          const SizedBox(height: 16),
          _field(_url, tr(context, 'Odoo URL'), 'https://your-build.dev.odoo.com', 'url'),
          _field(_db, tr(context, 'Database'), 'codesolutioneg-jouma-...', 'db'),
          _field(_login, tr(context, 'Login'), 'you@example.com', 'login'),
          _field(_pass, tr(context, 'Password'), '', 'pass', obscure: true),
          const SizedBox(height: 16),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_message!, key: const Key('settings-message')),
            ),
          FilledButton(
            key: const Key('save-server'),
            onPressed: _save,
            child: Text(tr(context, 'Save')),
          ),
        ],
      ),
    );
  }

  Widget _field(TextEditingController c, String label, String hint, String key,
          {bool obscure = false}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          key: Key('field-$key'),
          controller: c,
          obscureText: obscure,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            border: const OutlineInputBorder(),
          ),
        ),
      );
}
