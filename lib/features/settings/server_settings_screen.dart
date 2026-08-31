import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/db/settings_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/sync/odoo_endpoint.dart';
import '../../core/sync/odoo_site.dart';
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
    this.loadChoices,
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

  /// Asks Odoo which branches, points of sale and warehouses exist, so the three
  /// ids are chosen from a list instead of guessed. Called once when the screen
  /// opens and never from anywhere that sells. Null, or an answer that never
  /// arrives, leaves the pickers on whatever this till last cached, and in either
  /// case the ids already saved stand.
  final Future<OdooSiteChoices> Function()? loadChoices;

  @override
  State<ServerSettingsScreen> createState() => _ServerSettingsScreenState();
}

class _ServerSettingsScreenState extends State<ServerSettingsScreen> {
  late final TextEditingController _url;
  late final TextEditingController _db;
  late final TextEditingController _login;
  late final TextEditingController _pass;
  late final TextEditingController _discountProduct;
  late final TextEditingController _localProduct;
  late bool _mergeBatch;
  String? _message;
  bool _checking = false;

  /// The three ids as chosen on screen. Held as ids rather than as text, because
  /// they are picked from a list now, and null means "let Odoo decide", which is
  /// what an empty box used to mean.
  int? _branchId;
  int? _restaurantId;
  int? _warehouseId;

  /// What the pickers offer. Seeded from the till's cache so a manager sees names
  /// before, and without, any answer from the server.
  OdooSiteChoices _choices = const OdooSiteChoices();
  bool _loadingChoices = false;

  /// True once a fetch came back with nothing to add. The screen says so and then
  /// leaves every saved id exactly where it was: an unreachable server is not a
  /// reason to reconfigure a till.
  bool _choicesUnavailable = false;

  @override
  void initState() {
    super.initState();
    final e = widget.store.load();
    _url = TextEditingController(text: e?.baseUrl ?? '');
    _db = TextEditingController(text: e?.db ?? '');
    _login = TextEditingController(text: e?.login ?? '');
    _pass = TextEditingController(text: e?.password ?? '');
    final s = widget.settings;
    _branchId = s?.odooBranchId;
    _restaurantId = s?.odooRestaurantId;
    _warehouseId = s?.odooWarehouseId;
    _choices = s?.odooSiteChoices ?? const OdooSiteChoices();
    _discountProduct =
        TextEditingController(text: s?.odooDiscountProductId?.toString() ?? '');
    _localProduct =
        TextEditingController(text: s?.odooLocalProductId?.toString() ?? '');
    _mergeBatch = s?.mergeBatchIntoOneSaleOrder ?? false;
    // Opening a settings screen is the one moment asking the server is free. It is
    // deliberately not awaited: nothing on this screen waits for it, and nothing
    // that takes money can reach it.
    if (s != null && widget.loadChoices != null) unawaited(_fetchChoices());
  }

  @override
  void dispose() {
    _url.dispose();
    _db.dispose();
    _login.dispose();
    _pass.dispose();
    _discountProduct.dispose();
    _localProduct.dispose();
    super.dispose();
  }

  /// Ask Odoo what it has, once, and keep whatever it gave.
  ///
  /// A list that comes back empty is never written over a cached one: an empty
  /// answer and a refused question look identical from here, and only one of them
  /// is a reason to stop showing a manager the names their shop had yesterday.
  Future<void> _fetchChoices() async {
    setState(() => _loadingChoices = true);
    try {
      final fresh = await widget.loadChoices!();
      if (!mounted) return;
      final merged = OdooSiteChoices(
        branches: fresh.branches.isEmpty ? _choices.branches : fresh.branches,
        pointsOfSale:
            fresh.pointsOfSale.isEmpty ? _choices.pointsOfSale : fresh.pointsOfSale,
        warehouses:
            fresh.warehouses.isEmpty ? _choices.warehouses : fresh.warehouses,
      );
      widget.settings?.odooSiteChoices = merged;
      setState(() {
        _choices = merged;
        _loadingChoices = false;
        _choicesUnavailable = fresh.isEmpty;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingChoices = false;
        _choicesUnavailable = true;
      });
    }
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
    // The ids are saved even when one of them is unset: leaving a picker on "let
    // Odoo decide" is how a shop says it has only one of that thing.
    final s = widget.settings;
    if (s != null) {
      s.odooBranchId = _branchId;
      s.odooRestaurantId = _restaurantId;
      s.odooWarehouseId = _warehouseId;
      s.odooDiscountProductId = int.tryParse(_discountProduct.text.trim());
      s.odooLocalProductId = int.tryParse(_localProduct.text.trim());
      s.mergeBatchIntoOneSaleOrder = _mergeBatch;
    }
    widget.onSaved(e);
    setState(() => _message = tr(context, 'Saved. Queued sales will sync on the next attempt.'));
    // A fresh till has nowhere to read the lists from until this moment, so the
    // pickers fill in once the address is saved rather than staying empty until
    // somebody comes back to the screen. After [onSaved], which is what points the
    // sender at the server this is about to ask.
    if (widget.loadChoices != null && s != null) unawaited(_fetchChoices());
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
                    'Pick these from what Odoo has. Leave one on "Let Odoo decide" '
                    'if the shop has only one of that thing. Every sale this till '
                    'sends carries them.'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (_loadingChoices)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(children: [
                  const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Text(tr(context, 'Reading the lists from Odoo...'),
                      style: Theme.of(context).textTheme.bodySmall),
                ]),
              ),
            if (_choicesUnavailable)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  tr(context,
                      'The lists could not be read from Odoo. What is saved below '
                      'still stands and still travels on every sale.'),
                  key: const Key('choices-unavailable'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            _picker(
              name: 'branch',
              label: tr(context, 'Branch (company)'),
              options: _choices.branches,
              value: _branchId,
              onPicked: (v) => _branchId = v,
            ),
            _picker(
              name: 'restaurant',
              label: tr(context, 'Restaurant (point of sale)'),
              options: _choices.pointsOfSale,
              value: _restaurantId,
              onPicked: (v) => _restaurantId = v,
              withinBranch: _branchId,
            ),
            _picker(
              name: 'warehouse',
              label: tr(context, 'Warehouse'),
              options: _choices.warehouses,
              value: _warehouseId,
              onPicked: (v) => _warehouseId = v,
              withinBranch: _branchId,
            ),
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
            const Divider(height: 24),
            SwitchListTile(
              key: const Key('merge-batch'),
              contentPadding: EdgeInsets.zero,
              value: _mergeBatch,
              onChanged: (v) => setState(() => _mergeBatch = v),
              title: Text(tr(context, 'Send a shift as one sales order')),
              subtitle: Text(tr(context,
                  'Needs a change in Odoo first. Leave off until it is deployed.')),
            ),
            Container(
              key: const Key('merge-batch-warning'),
              color: Colors.amber.shade100,
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 12),
              child: Text(
                tr(context,
                    'Turned on, a shift close sends the whole night as one sales '
                    'order carrying the branch, restaurant and warehouse. Odoo '
                    'has to be changed to accept it. Until that change is live, '
                    'the night books as one document with no record of which sale '
                    'was which and no protection against a retry booking it '
                    'twice. Ask whoever looks after Odoo before turning this on.'),
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

  /// One of the three ids, chosen from what Odoo has.
  Widget _picker({
    required String name,
    required String label,
    required List<OdooSiteOption> options,
    required int? value,
    required void Function(int?) onPicked,
    int? withinBranch,
  }) {
    final offered = _offer(options, value, withinBranch);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<int?>(
        key: Key('pick-$name'),
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        items: [
          DropdownMenuItem<int?>(
            value: null,
            child: Text(tr(context, 'Let Odoo decide')),
          ),
          for (final o in offered)
            DropdownMenuItem<int?>(value: o.id, child: Text(_optionLabel(o))),
        ],
        onChanged: (v) => setState(() => onPicked(v)),
      ),
    );
  }

  /// The rows one picker offers: what Odoo listed, narrowed to the chosen branch
  /// where the records say which branch they belong to, and always including
  /// [selected] even when it is in neither.
  ///
  /// That last part is the rule this screen turns on. A list that could not be
  /// fetched, a warehouse that moved company, an id typed in before this screen had
  /// pickers at all: none of them may make a configured id unselectable, because
  /// dropping it silently re-points the till at whatever Odoo would have picked.
  List<OdooSiteOption> _offer(
      List<OdooSiteOption> options, int? selected, int? branch) {
    final narrowed = [
      for (final o in options)
        // A record naming no company belongs to every branch as far as this screen
        // is concerned, which is the reading that hides the least.
        if (branch == null ||
            o.companyId == null ||
            o.companyId == branch ||
            o.id == selected)
          o,
    ];
    if (selected == null || narrowed.any((o) => o.id == selected)) return narrowed;
    return [OdooSiteOption(id: selected, name: ''), ...narrowed];
  }

  /// The id is shown next to the name because two branches often read the same on
  /// screen, and it is all a saved-but-unlisted record has to go on.
  String _optionLabel(OdooSiteOption o) => o.name.isEmpty
      ? '${o.id} (${tr(context, 'not in the list')})'
      : '${o.name} (${o.id})';

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
