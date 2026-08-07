import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/db/sqlite_outbox_store.dart';
import '../../core/sync/sync_service.dart';

/// What support reads out over the phone.
///
/// Everything here comes from local storage, so it works during exactly the outage
/// you are calling about. The point is that a shop can be diagnosed without anyone
/// driving to it, and without asking a cashier to describe a spinner.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({
    super.key,
    required this.sync,
    required this.outboxStore,
  });

  final SyncService sync;
  final SqliteOutboxStore outboxStore;

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  bool _syncing = false;

  Future<void> _syncNow() async {
    setState(() => _syncing = true);
    await widget.sync.tick();
    if (mounted) setState(() => _syncing = false);
  }

  String _age(Duration? d) {
    if (d == null) return '-';
    if (d.inDays > 0) return '${d.inDays}d ${d.inHours % 24}h';
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
    return '${d.inMinutes}m';
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.sync.status();
    final dead = widget.outboxStore.dead(limit: 20);

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
          _row('Device', s.deviceId, keyName: 'device'),
          _row('App version', s.appVersion),
          _row('Signed in', s.cashierId ?? '-'),
          const Divider(),
          _row('Connection', switch (widget.sync.state) {
            SyncState.idle => 'Online',
            SyncState.working => 'Syncing',
            SyncState.offline => 'Offline',
          }, keyName: 'connection'),
          _row('Sales waiting', '${s.pending}', keyName: 'pending'),
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
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('sync-now'),
            onPressed: _syncing ? null : _syncNow,
            icon: const Icon(Icons.sync),
            label: Text(_syncing ? 'Syncing...' : 'Sync now'),
          ),
          if (dead.isNotEmpty) ...[
            const SizedBox(height: 16),
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
          ],
        ],
      ),
    );
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
