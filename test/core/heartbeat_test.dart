import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/core/sync/sync_service.dart';

import '../db/sqlite_loader.dart';

void main() {
  late Db db;
  late SqliteOutboxStore store;
  late AuditLog audit;
  late SyncService sync;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    store = SqliteOutboxStore(db);
    audit = AuditLog(db);
    sync = SyncService(
      outbox: Outbox(store: store, senders: const {}), // nothing sends yet
      catalogue: CatalogueStore(db),
      outboxStore: store,
      audit: audit,
      deviceId: 'till-7',
      appVersion: '1.2.3',
    );
  });
  tearDown(() => db.close());

  test('the heartbeat carries what support needs', () async {
    await store.append('order.push', 'a', {});
    audit.record('sara', 'order.paid');
    final s = sync.status();
    expect(s.deviceId, 'till-7');
    expect(s.pending, 1);
    expect(s.unsyncedAudit, 1);
    expect(s.toMap()['needs_attention'], isFalse);
  });

  test('a rejected sale marks the till as needing attention', () async {
    await store.append('order.push', 'bad', {});
    await store.markDead(1, 'rejected');
    expect(sync.status().needsAttention, isTrue);
  });

  test('heartbeats replace rather than pile up during a long outage', () async {
    await sync.tick();
    await sync.tick();
    await sync.tick();
    final beats = (await store.pending(limit: 100))
        .where((e) => e.kind == 'device.status');
    // Unique on (kind, uuid) keyed by device, so support gets the latest state
    // and not a week of stale ones.
    expect(beats.length, 1);
  });

  test('the audit trail is handed to the outbox, since Odoo cannot attribute it',
      () async {
    audit.record('sara', 'pin.unlock');
    audit.record('sara', 'order.paid');
    await sync.tick();
    final queued = (await store.pending(limit: 100))
        .where((e) => e.kind == 'audit.push');
    expect(queued.length, 2);
    // Handed over, so the next tick does not queue them a second time.
    expect(audit.unsyncedCount, 0);
    await sync.tick();
    expect(
        (await store.pending(limit: 100)).where((e) => e.kind == 'audit.push').length,
        2);
  });

  test('oldest waiting age is what says how bad an outage is', () async {
    await store.append('order.push', 'a', {});
    final age = store.oldestPendingAge(DateTime.now().toUtc().add(const Duration(days: 6)));
    expect(age!.inDays, 6);
  });
}
