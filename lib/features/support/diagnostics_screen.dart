import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/auth/permissions.dart';
import '../../core/db/sqlite_outbox_store.dart';
import '../../core/diagnostics/startup_log.dart';
import '../../core/i18n/l10n.dart';
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
    this.authorize,
    this.onBackup,
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

  /// Copies the whole encrypted database somewhere a human can pick it up, and
  /// returns where it landed. Null on a build with nowhere to write, which hides
  /// the action rather than offering one that cannot work.
  final Future<String> Function()? onBackup;

  /// Gate for adding, editing or forgetting a printer here: it is the same
  /// managePrinters right the Settings printer screen uses, so support cannot be a
  /// back door around it. Reprint and find-printer stay open to any cashier.
  final Future<bool> Function(Permission)? authorize;

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  bool _syncing = false;
  String? _printerBusy;

  /// Where the last backup landed, or why there is none. A path a cashier can read
  /// out is the whole point of the button.
  String? _backupMessage;

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

  /// Take a copy of the till, on demand.
  ///
  /// Manager-gated like every other configuration action here: the file is
  /// encrypted, but it is still every sale the shop has taken.
  Future<void> _backup() async {
    if (widget.authorize != null &&
        !await widget.authorize!(Permission.openSettings)) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _printerBusy = 'backup';
      _backupMessage = tr(context, 'Copying...');
    });
    try {
      final path = await widget.onBackup!();
      if (!mounted) return;
      setState(() => _backupMessage = path);
    } catch (e) {
      if (!mounted) return;
      // Says what went wrong rather than leaving a manager believing there is a
      // backup somewhere.
      setState(() => _backupMessage = '${tr(context, 'Backup failed')}: $e');
    } finally {
      if (mounted) setState(() => _printerBusy = null);
    }
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
    // Adding, repointing or forgetting a printer is manager-gated, exactly as in
    // Settings, so Support is not a way around the printer permission.
    if (widget.authorize != null && !await widget.authorize!(Permission.managePrinters)) {
      return;
    }
    if (!mounted) return;
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
    if (!widget.sync.hasDestination) return tr(context, 'No server configured');
    return switch (widget.sync.state) {
      SyncState.idle => tr(context, 'Online'),
      SyncState.working => tr(context, 'Syncing'),
      SyncState.offline => tr(context, 'Offline'),
    };
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.sync.status();
    final dead = widget.outboxStore.dead(limit: 20);
    final undeliverable = widget.sync.undeliverableKinds;

    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Diagnostics')),
        actions: [
          IconButton(
            key: const Key('copy-status'),
            tooltip: tr(context, 'Copy for support'),
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
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(tr(context, 'This till needs attention'),
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          // First, because every one of these is money that never reached the
          // books. Nothing else on this screen outranks that.
          if (dead.isNotEmpty) ...[
            Text(tr(context, 'Rejected sales'),
                style: const TextStyle(fontWeight: FontWeight.bold)),
            Text(
              tr(context, 'These never reached the server. Fix the cause, then retry.'),
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
            for (final e in dead)
              ListTile(
                key: Key('dead-${e.id}'),
                dense: true,
                title: Text(e.payloadUuid),
                subtitle: Text(e.lastError ?? tr(context, 'unknown reason')),
                trailing: TextButton(
                  child: Text(tr(context, 'Retry')),
                  onPressed: () => setState(() => widget.outboxStore.revive(e.id)),
                ),
              ),
            const Divider(),
          ],
          _row(tr(context, 'Device'), s.deviceId, keyName: 'device'),
          _row(tr(context, 'App version'), s.appVersion),
          // The launch trail, so it can be asked for on a till that did open and
          // is merely misbehaving. A till that never opened shows the same path on
          // the screen it puts up instead.
          _row(tr(context, 'Startup log'), StartupLog.thisLaunchPath),
          _row(tr(context, 'Signed in'), widget.cashierId ?? s.cashierId ?? '-'),
          const Divider(),
          _row(tr(context, 'Connection'), _connection, keyName: 'connection',
              bad: !widget.sync.hasDestination),
          if (undeliverable.isNotEmpty)
            _row(tr(context, 'Nothing can send'), undeliverable.join(', '),
                keyName: 'undeliverable', bad: true),
          _row(tr(context, 'Sales waiting'), '${widget.outboxStore.pendingSalesCount}',
              keyName: 'pending'),
          _row(tr(context, 'Everything waiting'), '${s.pending}', keyName: 'queued'),
          // The number that says how bad it is. A count alone hides whether it is
          // ten minutes or six days.
          _row(tr(context, 'Oldest waiting'), _age(s.oldestPendingAge), keyName: 'oldest'),
          _row(tr(context, 'Rejected'), '${s.dead}',
              keyName: 'dead', bad: s.dead > 0),
          _row(tr(context, 'Audit entries waiting'), '${s.unsyncedAudit}'),
          _row(tr(context, 'Prices updated'), _age(s.catalogueRefreshedAt == null
              ? null
              : DateTime.now().toUtc().difference(s.catalogueRefreshedAt!))),
          if (s.lastError != null)
            _row(tr(context, 'Last error'), s.lastError!, keyName: 'last-error', bad: true),
          if (widget.printError != null)
            _row(tr(context, 'Receipt not built'), widget.printError!,
                keyName: 'print-error', bad: true),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('sync-now'),
            onPressed: _syncing ? null : _syncNow,
            icon: const Icon(Icons.sync),
            label: Text(_syncing ? tr(context, 'Syncing...') : tr(context, 'Sync now')),
          ),
          ..._updateSection(),
          if (widget.onBackup != null) ..._backupSection(),
          if (widget.printers != null) ..._printerSection(),
          if (widget.wizards != null && widget.cashierId != null)
            TextButton.icon(
              key: const Key('reset-help'),
              onPressed: () {
                widget.wizards!.reset(cashierId: widget.cashierId);
                setState(() {});
              },
              icon: const Icon(Icons.help_outline),
              label: Text(tr(context, 'Show the walkthroughs again')),
            ),
        ],
      ),
    );
  }

  List<Widget> _updateSection() {
    final updates = widget.updates;
    return [
      const SizedBox(height: 16),
      Text(tr(context, 'Updates'), style: const TextStyle(fontWeight: FontWeight.bold)),
      if (updates == null)
        Text(
          tr(context, 'No update channel in this build. New versions are installed by hand.'),
          key: const Key('no-updates'),
          style: const TextStyle(fontSize: 12, color: Colors.black54),
        )
      else ...[
        Text(updates.status.summary, key: const Key('update-summary')),
        TextButton.icon(
          key: const Key('check-update'),
          onPressed: _printerBusy == null ? _checkForUpdate : null,
          icon: const Icon(Icons.system_update),
          label: Text(_printerBusy == 'update' ? tr(context, 'Checking...') : tr(context, 'Check now')),
        ),
      ],
    ];
  }

  /// One copy of the whole till, encrypted exactly as it sits on disk, for the day
  /// the machine does not come back on.
  List<Widget> _backupSection() => [
        const SizedBox(height: 16),
        Text(tr(context, 'Backup'), style: const TextStyle(fontWeight: FontWeight.bold)),
        Text(
          tr(context,
              'A copy of everything on this till, including sales that have not synced. It stays encrypted.'),
          style: const TextStyle(fontSize: 12, color: Colors.black54),
        ),
        TextButton.icon(
          key: const Key('backup-db'),
          onPressed: _printerBusy == null ? _backup : null,
          icon: const Icon(Icons.save_alt),
          label: Text(_printerBusy == 'backup'
              ? tr(context, 'Copying...')
              : tr(context, 'Back up now')),
        ),
        if (_backupMessage != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SelectableText(_backupMessage!, key: const Key('backup-result')),
          ),
      ];

  /// Printers are listed by name, because that is what a receipt is routed by. The
  /// address underneath is only the last one that answered, and support needs to see
  /// when it last did to know whether the printer or the network is the problem.
  List<Widget> _printerSection() {
    final registry = widget.printers!;
    final spool = widget.spool;
    return [
      const SizedBox(height: 16),
      Text(tr(context, 'Printers'), style: const TextStyle(fontWeight: FontWeight.bold)),
      if (registry.printers.isEmpty)
        Text(
          tr(context, 'No printer configured. Receipts are held until one is.'),
          style: const TextStyle(fontSize: 12, color: Colors.black54),
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
            child: Text(_printerBusy == p.name ? tr(context, 'Looking...') : tr(context, 'Rescan')),
          ),
        ),
      TextButton.icon(
        key: const Key('find-printer'),
        onPressed: _printerBusy == null ? _findReceiptPrinter : null,
        icon: const Icon(Icons.search),
        label: Text(tr(context, 'Find receipt printer')),
      ),
      TextButton.icon(
        key: const Key('add-printer'),
        onPressed: _printerBusy == null ? () => _editPrinter() : null,
        icon: const Icon(Icons.edit),
        label: Text(tr(context, 'Enter a printer address')),
      ),
      if (spool != null && spool.hasSpooled) ...[
        TextButton.icon(
          key: const Key('reprint'),
          onPressed: _printerBusy == null ? _reprint : null,
          icon: const Icon(Icons.print),
          label: Text('${tr(context, 'Reprint')} ${spool.spooledCount} ${tr(context, 'held receipt(s)')}'),
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
                  title: Text(job.reference ?? '${tr(context, 'receipt')} ${job.id}'),
                  subtitle: Text(job.lastError ?? tr(context, 'not attempted since it was held')),
                ),
            ],
          ),
        ),
      ],
    ];
  }

  String _printerLine(ConfiguredPrinter p) {
    if (p.host == null) return tr(context, 'never found');
    final seen = p.lastSeenAt == null
        ? '-'
        : _age(DateTime.now().difference(p.lastSeenAt!));
    // Says why the till is not sweeping, so "it just stopped looking" is never a
    // mystery on a support call.
    final held = widget.printers!.sweepHeldOffFor(p.name)
        ? '  ${tr(context, 'not searching (last sweep found nothing)')}'
        : '';
    return '${p.host}:${p.port}  ${tr(context, 'last seen')} $seen ${tr(context, 'ago')}$held';
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
        title: Text(widget.existing == null ? tr(context, 'Add a printer') : tr(context, 'Edit printer')),
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
              decoration: InputDecoration(
                  labelText: tr(context, 'Name (receipt, kitchen, bar)')),
            ),
            TextField(
              key: const Key('printer-host'),
              controller: _host,
              decoration: InputDecoration(labelText: tr(context, 'Address')),
            ),
            TextField(
              key: const Key('printer-port'),
              controller: _port,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: tr(context, 'Port')),
            ),
          ],
        ),
        actions: [
          if (widget.existing != null)
            TextButton(
              key: const Key('printer-delete'),
              onPressed: () => Navigator.of(context).pop(
                  _PrinterEdit(widget.existing!.name, null, 0, deleted: true)),
              child: Text(tr(context, 'Remove')),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr(context, 'Cancel')),
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
            child: Text(tr(context, 'Save')),
          ),
        ],
      );
}
