import 'package:flutter/material.dart';

import '../../core/db/settings_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/sync/odoo_endpoint.dart';
import '../../core/sync/server_probe.dart';

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
    this.check,
    this.settings,
  });

  final OdooEndpointStore store;

  /// Where the ids that say which shop this till is live. Optional, and those
  /// fields are simply absent without it: a build that cannot store them is better
  /// off not offering boxes that forget what is typed in them.
  final SettingsStore? settings;

  /// Called with the saved endpoint so the app can (re)wire the sender live.
  final void Function(OdooEndpoint) onSaved;

  /// Asks the server whether it is there and whether it knows this login. Null
  /// hides the button, for a build with no way to reach out.
  final Future<ServerCheckResult> Function(OdooEndpoint)? check;

  @override
  State<ServerSettingsScreen> createState() => _ServerSettingsScreenState();
}

class _ServerSettingsScreenState extends State<ServerSettingsScreen> {
  late final TextEditingController _url;
  late final TextEditingController _db;
  late final TextEditingController _login;
  late final TextEditingController _pass;
  late final TextEditingController _branch;
  late final TextEditingController _restaurant;
  late final TextEditingController _warehouse;
  late final TextEditingController _discountProduct;
  late final TextEditingController _localProduct;
  String? _message;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    final e = widget.store.load();
    _url = TextEditingController(text: e?.baseUrl ?? '');
    _db = TextEditingController(text: e?.db ?? '');
    _login = TextEditingController(text: e?.login ?? '');
    _pass = TextEditingController(text: e?.password ?? '');
    final s = widget.settings;
    _branch = TextEditingController(text: s?.odooBranchId?.toString() ?? '');
    _restaurant = TextEditingController(text: s?.odooRestaurantId?.toString() ?? '');
    _warehouse = TextEditingController(text: s?.odooWarehouseId?.toString() ?? '');
    _discountProduct =
        TextEditingController(text: s?.odooDiscountProductId?.toString() ?? '');
    _localProduct =
        TextEditingController(text: s?.odooLocalProductId?.toString() ?? '');
  }

  @override
  void dispose() {
    _url.dispose();
    _db.dispose();
    _login.dispose();
    _pass.dispose();
    _branch.dispose();
    _restaurant.dispose();
    _warehouse.dispose();
    _discountProduct.dispose();
    _localProduct.dispose();
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
    // The ids are saved even when one of them is blank: leaving a box empty is how
    // a shop says it has only one of that thing and wants Odoo to decide.
    final s = widget.settings;
    if (s != null) {
      s.odooBranchId = int.tryParse(_branch.text.trim());
      s.odooRestaurantId = int.tryParse(_restaurant.text.trim());
      s.odooWarehouseId = int.tryParse(_warehouse.text.trim());
      s.odooDiscountProductId = int.tryParse(_discountProduct.text.trim());
      s.odooLocalProductId = int.tryParse(_localProduct.text.trim());
    }
    widget.onSaved(e);
    setState(() => _message = tr(context, 'Saved. Queued sales will sync on the next attempt.'));
  }

  /// Ask the server, and say which kind of no it was.
  ///
  /// Checks what is typed on screen rather than what is saved, so a manager can try
  /// a correction before committing it to the till.
  Future<void> _test() async {
    final e = OdooEndpoint(
      baseUrl: _url.text.trim(),
      db: _db.text.trim(),
      login: _login.text.trim(),
      password: _pass.text.isEmpty ? null : _pass.text,
    );
    setState(() {
      _checking = true;
      _message = tr(context, 'Asking the server...');
    });
    final result = await widget.check!(e);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _message = switch (result.outcome) {
        ServerCheck.ok => tr(context, 'Connected. The login was accepted.'),
        ServerCheck.notConfigured =>
          tr(context, 'URL, database and login are all required.'),
        ServerCheck.unreachable => '${tr(context, 'No answer from that address.')}'
            '${result.detail == null ? '' : ' (${result.detail})'}',
        ServerCheck.refused => '${tr(context, 'Something answered, but it is not an Odoo server.')}'
            '${result.detail == null ? '' : ' (${result.detail})'}',
        ServerCheck.badCredentials =>
          '${tr(context, 'The server is up, but it refused this login.')}'
              '${result.detail == null ? '' : ' (${result.detail})'}',
      };
    });
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
          if (widget.settings != null) ...[
            const SizedBox(height: 8),
            Text(tr(context, 'Where this till books in Odoo'),
                style: const TextStyle(fontWeight: FontWeight.bold)),
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 12),
              child: Text(
                tr(context,
                    'Odoo record numbers, taken from the address bar of each record. '
                    'Leave a box empty to let Odoo decide. Every sale this till sends '
                    'carries them.'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            _field(_branch, tr(context, 'Branch id (company)'), '1', 'branch',
                numeric: true),
            _field(_restaurant, tr(context, 'Restaurant id (point of sale)'), '1',
                'restaurant',
                numeric: true),
            _field(_warehouse, tr(context, 'Warehouse id'), '1', 'warehouse',
                numeric: true),
            _field(
                _discountProduct,
                tr(context, 'Discount product id (a service product)'),
                '',
                'discount-product',
                numeric: true),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                tr(context,
                    'With a product here, a discounted sale reaches Odoo at full '
                    'menu prices plus one discount line, so it can be reported on '
                    'there. Empty keeps the discount inside the prices.'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            _field(
                _localProduct,
                tr(context, 'Stand-in product id for unlinked items (a service product)'),
                '',
                'local-product',
                numeric: true),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                tr(context,
                    'An item created on the till and not yet linked to an Odoo '
                    'product books against this one, under its own name. Empty '
                    'means such a sale is held back for someone to sort out.'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
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
          if (widget.check != null) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('test-connection'),
              onPressed: _checking ? null : _test,
              icon: _checking
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.network_check),
              label: Text(tr(context, 'Test connection')),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                tr(context,
                    'Nothing is sent or booked. Queued sales still go out at shift close.'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _field(TextEditingController c, String label, String hint, String key,
          {bool obscure = false, bool numeric = false}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          key: Key('field-$key'),
          controller: c,
          obscureText: obscure,
          keyboardType: numeric ? TextInputType.number : null,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            border: const OutlineInputBorder(),
          ),
        ),
      );
}
