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

  test('a till that has only ever queued heartbeats is not an outage', () async {
    await sync.tick();
    await sync.tick();

    // The heartbeat is keyed on the device and replaced in place every 30 s, and
    // `append` deliberately keeps the original created_at, so that row carries the
    // timestamp of the very first launch forever. Counting it would make "oldest
    // waiting" mean "time since this till was installed" the moment delivery
    // stopped, and the red banner would latch on 24 hours after install and never
    // clear. Support triages on these two numbers.
    final sixDaysOn = SyncService(
      outbox: Outbox(store: store, senders: const {}),
      catalogue: CatalogueStore(db),
      outboxStore: store,
      audit: audit,
      deviceId: 'till-7',
      appVersion: '1.2.3',
      now: () => DateTime.now().toUtc().add(const Duration(days: 6)),
    );

    final s = sixDaysOn.status();
    expect(s.pending, 0);
    expect(s.oldestPendingAge, isNull);
    expect(s.needsAttention, isFalse);
  });

  test('a real sale behind the heartbeat is still counted and still aged',
      () async {
    await sync.tick();
    await store.append('order.push', 'a', {});

    expect(store.pendingCount, 1);
    expect(store.pendingSalesCount, 1);
    expect(
      store.oldestPendingAge(DateTime.now().toUtc().add(const Duration(hours: 3)))!
          .inHours,
      3,
    );
  });
}
