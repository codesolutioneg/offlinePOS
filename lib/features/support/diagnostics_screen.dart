import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/db/sqlite_outbox_store.dart';
import '../../core/onboarding/wizard_store.dart';
import '../../core/printing/printer_registry.dart';
import '../../core/printing/printer_transport.dart';
import '../../core/printing/spool_store.dart';
import '../../core/sync/sync_service.dart';
import '../../core/updates/update_service.dart';

/// What support reads out over the phone.
///
/// Everything here comes from local storage, so it works during exactly the outage
/// you are calling about. The point is that a shop can be diagnosed without anyone
/// driving to it, and without asking a cashier to describe a spinner.
///
/// Every number on this screen has to be the truth or the screen is worse than
/// nothing: a till that reports itself online and empty while a week of takings
/// sits on it sends support looking somewhere else.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({
    super.key,
    required this.sync,
    required this.outboxStore,
    this.printers,
    this.spool,
    this.updates,
    this.wizards,
    this.cashierId,
    this.printError,
  });

  final SyncService sync;
  final SqliteOutboxStore outboxStore;

  /// Optional so the screen can be looked at without a print path behind it.
  final PrinterRegistry? printers;

  /// Receipts that could not print. Reprinting them is the whole reason they were
  /// kept, and this is where a human can ask for it out of turn.
  final SpooledPrinter? spool;

  /// Null when this build has no update channel configured, which is itself
  /// something support needs to be told.
  final UpdateService? updates;

  /// For offering the coach wizards again to someone new on the till.
  final WizardStore? wizards;

  final String? cashierId;

  /// The last receipt that could not even be built. Distinct from a printer that
  /// is off, and invisible everywhere else.
  final String? printError;

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  bool _syncing = false;
  String? _printerBusy;

  Future<void> _syncNow() async {
    setState(() => _syncing = true);
    await widget.sync.tick();
    if (mounted) setState(() => _syncing = false);
  }

  /// Sweeps the subnet ignoring the address we last used, for when support already
  /// knows the printer moved. Also the signal that clears the cooling-off period a
  /// failed sweep imposes.
  Future<void> _rescan(String name) async {
    setState(() => _printerBusy = name);
    await widget.printers!.refresh(name);
    if (mounted) setState(() => _printerBusy = null);
  }

  /// Adopts a receipt printer without anyone reading an address off a label. Works
  /// when exactly one printer answers on the subnet; with several, the registry
  /// refuses to guess and the address is entered by hand below.
  Future<void> _findReceiptPrinter() async {
    widget.printers!.remember('receipt');
    await _rescan('receipt');
  }

  Future<void> _reprint() async {
    setState(() => _printerBusy = 'spool');
    await widget.spool!.flush();
    if (mounted) setState(() => _printerBusy = null);
  }

  Future<void> _checkForUpdate() async {
    setState(() => _printerBusy = 'update');
    await widget.updates!.check();
    if (mounted) setState(() => _printerBusy = null);
  }

  /// Name, address and port by hand, for the case the registry deliberately
  /// refuses to guess: several printers on the subnet and none of them saying who
  /// it is. Without this there is no route to a working printer at all.
  Future<void> _editPrinter({ConfiguredPrinter? existing}) async {
    final result = await showDialog<_PrinterEdit>(
      context: context,
      builder: (_) => _PrinterDialog(existing: existing),
    );
    if (result == null) return;
    final registry = widget.printers!;
    if (result.deleted) {
      registry.forget(result.name);
    } else {
      registry.remember(result.name, host: result.host, port: result.port);
    }
    if (mounted) setState(() {});
  }

  String _age(Duration? d) {
    if (d == null) return '-';
    if (d.inDays > 0) return '${d.inDays}d ${d.inHours % 24}h';
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
    return '${d.inMinutes}m';
  }

  /// Deliberately not "Online" by default.
  ///
  /// With no sender registered the till delivers nothing and never errors, so the
  /// old reading was "Online" on a machine that had never transmitted a byte. A
  /// till with nowhere to send is not offline; it is unconfigured, and support has
  /// to be told which.
  String get _connection {
    if (!widget.sync.hasDestination) return 'No server configured';
    return switch (widget.sync.state) {
      SyncState.idle => 'Online',
      SyncState.working => 'Syncing',
      SyncState.offline => 'Offline',
    };
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.sync.status();
    final dead = widget.outboxStore.dead(limit: 20);
    final undeliverable = widget.sync.undeliverableKinds;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: [
          IconButton(
            key: const Key('copy-status'),
            tooltip: 'Copy for support',
            icon: const Icon(Icons.copy),
            // A cashier can send this in one message instead of reading numbers
            // out incorrectly.
            onPressed: () => Clipboard.setData(
                ClipboardData(text: s.toMap().entries.join('\n'))),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (s.needsAttention)
            Card(
              key: const Key('attention'),
              color: Colors.red.shade100,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text('This till needs attention',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          // First, because every one of these is money that never reached the
          // books. Nothing else on this screen outranks that.
          if (dead.isNotEmpty) ...[
            const Text('Rejected sales',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const Text(
              'These never reached the server. Fix the cause, then retry.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            for (final e in dead)
              ListTile(
                key: Key('dead-${e.id}'),
                dense: true,
                title: Text(e.payloadUuid),
                subtitle: Text(e.lastError ?? 'unknown reason'),
                trailing: TextButton(
                  child: const Text('Retry'),
                  onPressed: () => setState(() => widget.outboxStore.revive(e.id)),
                ),
              ),
            const Divider(),
          ],
          _row('Device', s.deviceId, keyName: 'device'),
          _row('App version', s.appVersion),
          _row('Signed in', widget.cashierId ?? s.cashierId ?? '-'),
          const Divider(),
          _row('Connection', _connection, keyName: 'connection',
              bad: !widget.sync.hasDestination),
          if (undeliverable.isNotEmpty)
            _row('Nothing can send', undeliverable.join(', '),
                keyName: 'undeliverable', bad: true),
          _row('Sales waiting', '${widget.outboxStore.pendingSalesCount}',
              keyName: 'pending'),
          _row('Everything waiting', '${s.pending}', keyName: 'queued'),
          // The number that says how bad it is. A count alone hides whether it is
          // ten minutes or six days.
          _row('Oldest waiting', _age(s.oldestPendingAge), keyName: 'oldest'),
          _row('Rejected', '${s.dead}',
              keyName: 'dead', bad: s.dead > 0),
          _row('Audit entries waiting', '${s.unsyncedAudit}'),
          _row('Prices updated', _age(s.catalogueRefreshedAt == null
              ? null
              : DateTime.now().toUtc().difference(s.catalogueRefreshedAt!))),
          if (s.lastError != null)
            _row('Last error', s.lastError!, keyName: 'last-error', bad: true),
          if (widget.printError != null)
            _row('Receipt not built', widget.printError!,
                keyName: 'print-error', bad: true),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('sync-now'),
            onPressed: _syncing ? null : _syncNow,
            icon: const Icon(Icons.sync),
            label: Text(_syncing ? 'Syncing...' : 'Sync now'),
          ),
          ..._updateSection(),
          if (widget.printers != null) ..._printerSection(),
          if (widget.wizards != null && widget.cashierId != null)
            TextButton.icon(
              key: const Key('reset-help'),
              onPressed: () {
                widget.wizards!.reset(cashierId: widget.cashierId);
                setState(() {});
              },
              icon: const Icon(Icons.help_outline),
              label: const Text('Show the walkthroughs again'),
            ),
        ],
      ),
    );
  }

  List<Widget> _updateSection() {
    final updates = widget.updates;
    return [
      const SizedBox(height: 16),
      const Text('Updates', style: TextStyle(fontWeight: FontWeight.bold)),
      if (updates == null)
        const Text(
          'No update channel in this build. New versions are installed by hand.',
          key: Key('no-updates'),
          style: TextStyle(fontSize: 12, color: Colors.black54),
        )
      else ...[
        Text(updates.status.summary, key: const Key('update-summary')),
        TextButton.icon(
          key: const Key('check-update'),
          onPressed: _printerBusy == null ? _checkForUpdate : null,
          icon: const Icon(Icons.system_update),
          label: Text(_printerBusy == 'update' ? 'Checking...' : 'Check now'),
        ),
      ],
    ];
  }

  /// Printers are listed by name, because that is what a receipt is routed by. The
  /// address underneath is only the last one that answered, and support needs to see
  /// when it last did to know whether the printer or the network is the problem.
  List<Widget> _printerSection() {
    final registry = widget.printers!;
    final spool = widget.spool;
    return [
      const SizedBox(height: 16),
      const Text('Printers', style: TextStyle(fontWeight: FontWeight.bold)),
      if (registry.printers.isEmpty)
        const Text(
          'No printer configured. Receipts are held until one is.',
          style: TextStyle(fontSize: 12, color: Colors.black54),
        ),
      for (final p in registry.printers)
        ListTile(
          key: Key('printer-${p.name}'),
          dense: true,
          title: Text(p.name),
          subtitle: Text(_printerLine(p)),
          onTap: () => _editPrinter(existing: p),
          trailing: TextButton(
            onPressed: _printerBusy == null ? () => _rescan(p.name) : null,
            child: Text(_printerBusy == p.name ? 'Looking...' : 'Rescan'),
          ),
        ),
      TextButton.icon(
        key: const Key('find-printer'),
        onPressed: _printerBusy == null ? _findReceiptPrinter : null,
        icon: const Icon(Icons.search),
        label: const Text('Find receipt printer'),
      ),
      TextButton.icon(
        key: const Key('add-printer'),
        onPressed: _printerBusy == null ? () => _editPrinter() : null,
        icon: const Icon(Icons.edit),
        label: const Text('Enter a printer address'),
      ),
      if (spool != null && spool.hasSpooled) ...[
        TextButton.icon(
          key: const Key('reprint'),
          onPressed: _printerBusy == null ? _reprint : null,
          icon: const Icon(Icons.print),
          label: Text('Reprint ${spool.spooledCount} held receipt(s)'),
        ),
        // Which sales have no paper, and why the last attempt failed. A count
        // alone cannot tell support whether the printer is off, out of paper, or
        // on an address nothing answers.
        FutureBuilder<List<SpooledJob>>(
          future: spool.held(limit: 10),
          builder: (_, snapshot) => Column(
            children: [
              for (final job in snapshot.data ?? const <SpooledJob>[])
                ListTile(
                  key: Key('held-${job.id}'),
                  dense: true,
                  title: Text(job.reference ?? 'receipt ${job.id}'),
                  subtitle: Text(job.lastError ?? 'not attempted since it was held'),
                ),
            ],
          ),
        ),
      ],
    ];
  }

  String _printerLine(ConfiguredPrinter p) {
    if (p.host == null) return 'never found';
    final seen = p.lastSeenAt == null
        ? '-'
        : _age(DateTime.now().difference(p.lastSeenAt!));
    // Says why the till is not sweeping, so "it just stopped looking" is never a
    // mystery on a support call.
    final held = widget.printers!.sweepHeldOffFor(p.name)
        ? '  not searching (last sweep found nothing)'
        : '';
    return '${p.host}:${p.port}  last seen $seen ago$held';
  }

  Widget _row(String label, String value, {String? keyName, bool bad = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(child: Text(label)),
            Text(
              value,
              key: keyName == null ? null : Key('diag-$keyName'),
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: bad ? Colors.red : null,
              ),
            ),
          ],
        ),
      );
}

class _PrinterEdit {
  const _PrinterEdit(this.name, this.host, this.port, {this.deleted = false});
  final String name;
  final String? host;
  final int port;
  final bool deleted;
}

/// Hand entry, for the case discovery cannot resolve on its own.
class _PrinterDialog extends StatefulWidget {
  const _PrinterDialog({this.existing});
  final ConfiguredPrinter? existing;

  @override
  State<_PrinterDialog> createState() => _PrinterDialogState();
}

class _PrinterDialogState extends State<_PrinterDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.existing?.name ?? 'receipt');
  late final TextEditingController _host =
      TextEditingController(text: widget.existing?.host ?? '');
  late final TextEditingController _port =
      TextEditingController(text: '${widget.existing?.port ?? 9100}');

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.existing == null ? 'Add a printer' : 'Edit printer'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('printer-name'),
              controller: _name,
              // The name is the routing key and part of what is on disk, so it is
              // fixed once a printer exists rather than silently orphaning its
              // held receipts.
              enabled: widget.existing == null,
              decoration: const InputDecoration(
                  labelText: 'Name (receipt, kitchen, bar)'),
            ),
            TextField(
              key: const Key('printer-host'),
              controller: _host,
              decoration: const InputDecoration(labelText: 'Address'),
            ),
            TextField(
              key: const Key('printer-port'),
              controller: _port,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Port'),
            ),
          ],
        ),
        actions: [
          if (widget.existing != null)
            TextButton(
              key: const Key('printer-delete'),
              onPressed: () => Navigator.of(context).pop(
                  _PrinterEdit(widget.existing!.name, null, 0, deleted: true)),
              child: const Text('Remove'),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('printer-save'),
            onPressed: () {
              final name = _name.text.trim();
              if (name.isEmpty) return;
              final host = _host.text.trim();
              Navigator.of(context).pop(_PrinterEdit(
                name,
                host.isEmpty ? null : host,
                int.tryParse(_port.text.trim()) ?? 9100,
              ));
            },
            child: const Text('Save'),
          ),
        ],
      );
}
