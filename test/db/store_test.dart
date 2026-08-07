import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/schema.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/domain/order.dart';

import 'sqlite_loader.dart';

Order sample({String cashier = 'sara'}) =>
    Order(deviceId: 'till-1', cashierId: cashier, lines: [
      OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 250, modifiers: [
        OrderModifier(modifierId: 1, name: 'Cheese', quantity: 1, unitPrice: 7),
      ]),
    ]);

void main() {
  late Db db;
  setUpAll(useSystemSqlite);
  setUp(() => db = Db.open(':memory:'));
  tearDown(() => db.close());

  test('migrations bring a fresh database to the current version', () {
    expect(db.userVersion, Schema.version);
  });

  test('migrating twice is a no-op', () {
    db.migrate();
    expect(db.userVersion, Schema.version);
  });

  test('an order round-trips through disk with its modifiers', () {
    final store = OrderStore(db);
    final o = sample();
    store.save(o);
    final back = store.byUuid(o.uuid)!;
    expect(back.total, o.total);
    expect(back.lines.single.modifiers.single.name, 'Cheese');
  });

  test('an unpaid order is restorable, which is what survives a crash', () {
    final store = OrderStore(db)..save(sample());
    expect(store.drafts().length, 1);
    expect(store.awaitingSync(), isEmpty);
  });

  test('saving the same order twice updates it rather than duplicating', () {
    final store = OrderStore(db);
    final o = sample();
    store.save(o);
    o.lines.single.quantity = 3;
    store.save(o);
    expect(store.count, 1);
    expect(store.byUuid(o.uuid)!.lines.single.quantity, 3);
  });

  test('marking synced moves it out of the pending set', () {
    final store = OrderStore(db);
    final o = sample()..state = OrderState.paid;
    store.save(o);
    expect(store.awaitingSync().length, 1);
    store.markSynced(o.uuid, 42);
    expect(store.awaitingSync(), isEmpty);
    expect(store.byUuid(o.uuid)!.serverId, 42);
  });

  test('outbox entries survive and stay pending until acknowledged', () async {
    final store = SqliteOutboxStore(db);
    await store.append('order.push', 'u1', {'total': 282});
    expect(store.pendingCount, 1);
    final entry = (await store.pending()).single;
    expect(entry.payload['total'], 282);
    await store.markSent(entry.id);
    expect(store.pendingCount, 0);
  });

  test('re-queuing the same record replaces it, so one sale is never sent twice', () async {
    final store = SqliteOutboxStore(db);
    await store.append('order.push', 'u1', {'total': 100});
    await store.append('order.push', 'u1', {'total': 282});
    expect(store.pendingCount, 1);
    expect((await store.pending()).single.payload['total'], 282);
  });

  test('a failure records the reason and keeps the entry', () async {
    final store = SqliteOutboxStore(db);
    await store.append('order.push', 'u1', {});
    final e = (await store.pending()).single;
    await store.markFailed(e.id, 'connection refused');
    final again = (await store.pending()).single;
    expect(again.attempts, 1);
    expect(again.lastError, 'connection refused');
  });

  test('delivery is FIFO', () async {
    final store = SqliteOutboxStore(db);
    for (final u in ['a', 'b', 'c']) {
      await store.append('order.push', u, {});
    }
    expect((await store.pending()).map((e) => e.payloadUuid), ['a', 'b', 'c']);
  });

  test('the durable store drains through Outbox once the line returns', () async {
    final store = SqliteOutboxStore(db);
    var online = false;
    final outbox = Outbox(store: store, senders: {
      'order.push': (e) async {
        if (!online) throw Exception('offline');
      },
    });
    await outbox.enqueue('order.push', 'u1', {});
    expect(await outbox.drain(), 0);
    expect(store.pendingCount, 1);
    online = true;
    expect(await outbox.drain(), 1);
    expect(store.pendingCount, 0);
  });

  test('acknowledged entries are pruned only after the retention window', () async {
    final store = SqliteOutboxStore(db);
    await store.append('order.push', 'u1', {});
    await store.markSent((await store.pending()).single.id);
    expect(store.pruneSent(olderThan: const Duration(days: 7)), 0);
    expect(store.pruneSent(olderThan: Duration.zero), 1);
  });
}
