import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/shift_store.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/lan/lan_event.dart';
import 'package:offline_pos/core/sync/batch_push.dart';
import 'package:offline_pos/core/sync/closed_shift_backlog.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/core/sync/sync_service.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/domain/shift.dart';

import '../db/sqlite_loader.dart';

/// H1 in `docs/POS_TEST_INCIDENTS_VS_OFFLINEPOS.md`: a retry of a close that
/// failed must book that shift's sales under that shift's key, never under the
/// key of a shift opened since.
void main() {
  late Db db;
  late ShiftStore shifts;
  late OrderStore orders;
  final t0 = DateTime.utc(2026, 9, 28, 18);

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    shifts = ShiftStore(db);
    orders = OrderStore(db, ownDeviceId: 'till-1');
  });
  tearDown(() => db.close());

  Order sale(DateTime at, {String device = 'till-1'}) {
    final o = Order(
      deviceId: device,
      cashierId: 'sara',
      createdAt: at,
      lines: [OrderLine(productId: 1, name: 'Item', quantity: 1, unitPrice: 50)],
    )..state = OrderState.paid;
    orders.save(o, announce: false);
    return o;
  }

  test('the failed night books under the night\'s key, not the morning\'s', () {
    final night = shifts.openShift(openingFloat: 0, cashierId: 'sara', at: t0);
    final evening = sale(t0.add(const Duration(hours: 2)));
    shifts.closeShift(countedCash: 0, at: t0.add(const Duration(hours: 6)));
    shifts.openShift(openingFloat: 0, cashierId: 'sara', at: t0.add(const Duration(hours: 14)));
    sale(t0.add(const Duration(hours: 15)));

    final backlog = nextClosedShiftBacklog(shifts, orders);

    expect(backlog?.batchKey, night.uuid);
    expect(backlog?.orders.map((o) => o.uuid), [evening.uuid],
        reason: 'the open shift\'s sales belong to its own close');
  });

  test('with every closed shift booked, the open shift\'s sales are not taken', () {
    shifts.openShift(openingFloat: 0, cashierId: 'sara', at: t0);
    shifts.closeShift(countedCash: 0, at: t0.add(const Duration(hours: 6)));
    shifts.openShift(openingFloat: 0, cashierId: 'sara', at: t0.add(const Duration(hours: 14)));
    sale(t0.add(const Duration(hours: 15)));

    expect(nextClosedShiftBacklog(shifts, orders), isNull);
  });

  test('a sale in no shift gets a key of its own, never a shift\'s', () {
    final night = shifts.openShift(openingFloat: 0, cashierId: 'sara', at: t0);
    shifts.closeShift(countedCash: 0, at: t0.add(const Duration(hours: 6)));
    final stray = sale(t0.subtract(const Duration(days: 2)));

    final backlog = nextClosedShiftBacklog(shifts, orders);

    expect(backlog?.batchKey, 'backlog-${stray.uuid}');
    expect(backlog?.batchKey, isNot(night.uuid));
  });

  test('a sale rung after the last close waits for the next close', () {
    shifts.openShift(openingFloat: 0, cashierId: 'sara', at: t0);
    shifts.closeShift(countedCash: 0, at: t0.add(const Duration(hours: 6)));
    final after = sale(t0.add(const Duration(hours: 6, minutes: 1)), device: 'till-2');

    expect(nextClosedShiftBacklog(shifts, orders), isNull,
        reason: 'another till may still be selling into the next session');

    final next = shifts.openShift(
        openingFloat: 0, cashierId: 'sara', at: t0.add(const Duration(hours: 14)));
    shifts.closeShift(countedCash: 0, at: t0.add(const Duration(hours: 20)));
    final backlog = nextClosedShiftBacklog(shifts, orders);
    expect(backlog?.batchKey, 'backlog-${after.uuid}',
        reason: 'it fell between the sessions, and is sent after the next close');
    expect(backlog?.batchKey, isNot(next.uuid));
  });

  test('a sale another till handed over is owed by its closed shift', () {
    final night = shifts.openShift(openingFloat: 0, cashierId: 'sara', at: t0);
    final mine = sale(t0.add(const Duration(hours: 1)));
    final peer = sale(t0.add(const Duration(hours: 2)), device: 'till-2');
    shifts.closeShift(countedCash: 0, at: t0.add(const Duration(hours: 6)));

    final backlog = nextClosedShiftBacklog(shifts, orders);

    expect(backlog?.batchKey, night.uuid);
    expect(backlog?.orders.map((o) => o.uuid), unorderedEquals([mine.uuid, peer.uuid]),
        reason: 'only the closing till sends, so a peer sale held here is owed here');
  });

  test('a peer sale in no shift is still picked up', () {
    shifts.openShift(openingFloat: 0, cashierId: 'sara', at: t0);
    shifts.closeShift(countedCash: 0, at: t0.add(const Duration(hours: 6)));
    final stray = sale(t0.subtract(const Duration(days: 1)), device: 'till-2');

    final backlog = nextClosedShiftBacklog(shifts, orders);

    expect(backlog?.batchKey, 'backlog-${stray.uuid}');
    expect(backlog?.orders.map((o) => o.uuid), [stray.uuid]);
  });

  test('a skipped shift moves on to the next one and keeps its sales out of the orphans', () {
    final first = shifts.openShift(openingFloat: 0, cashierId: 'sara', at: t0);
    final early = sale(t0.add(const Duration(hours: 1)));
    shifts.closeShift(countedCash: 0, at: t0.add(const Duration(hours: 6)));
    final second = shifts.openShift(
        openingFloat: 0, cashierId: 'sara', at: t0.add(const Duration(hours: 14)));
    final late = sale(t0.add(const Duration(hours: 15)));
    shifts.closeShift(countedCash: 0, at: t0.add(const Duration(hours: 20)));

    final backlog = nextClosedShiftBacklog(shifts, orders, skip: {first.uuid});

    expect(backlog?.batchKey, second.uuid);
    expect(backlog?.orders.map((o) => o.uuid), [late.uuid]);
    expect(
        nextClosedShiftBacklog(shifts, orders, skip: {first.uuid, second.uuid}),
        isNull,
        reason: '${early.uuid} belongs to a skipped shift, not to a new orphan batch');
  });

  group('sending the backlog', () {
    late Shift first;
    late Shift second;

    setUp(() {
      first = shifts.openShift(openingFloat: 0, cashierId: 'sara', at: t0);
      sale(t0.add(const Duration(hours: 1)));
      shifts.closeShift(countedCash: 0, at: t0.add(const Duration(hours: 6)));
      second = shifts.openShift(
          openingFloat: 0, cashierId: 'sara', at: t0.add(const Duration(hours: 14)));
      sale(t0.add(const Duration(hours: 15)));
      shifts.closeShift(countedCash: 0, at: t0.add(const Duration(hours: 20)));
    });

    Future<ShiftFlushResult> book(ClosedShiftBacklog backlog) async {
      for (final o in backlog.orders) {
        orders.markSynced(o.uuid, 1);
      }
      return ShiftFlushResult(merged: true, orderCount: backlog.orders.length);
    }

    test('every owed shift goes, oldest first', () async {
      final sent = <String>[];
      final result = await sendClosedShiftBacklog(shifts, orders, (b) {
        sent.add(b.batchKey);
        return book(b);
      }, outbox: SqliteOutboxStore(db));

      expect(sent, [first.uuid, second.uuid]);
      expect(result.merged, isTrue);
      expect(orders.awaitingSync(anyDevice: true), isEmpty);
    });

    test('a refused batch does not hold back the ones behind it', () async {
      final sent = <String>[];
      final result = await sendClosedShiftBacklog(shifts, orders, (b) async {
        sent.add(b.batchKey);
        if (b.batchKey == first.uuid) {
          return const ShiftFlushResult(
              merged: false, orderCount: 0, skipReason: 'refused', refused: true);
        }
        return book(b);
      }, outbox: SqliteOutboxStore(db));

      expect(sent, [first.uuid, second.uuid]);
      expect(result.refused, isTrue,
          reason: 'the refused batch is still owed and must be reported');
      expect(orders.awaitingSync(anyDevice: true), hasLength(1));
    });

    test('a booked peer sale is told to the shop so its till does not send it again', () async {
      final peer = sale(t0.add(const Duration(hours: 16)), device: 'till-2');
      final told = <String, Object?>{};
      final announcing = OrderStore(db,
          ownDeviceId: 'till-1',
          publish: (kind, uuid, payload) {
            if (kind == LanEventKind.orderUpsert) told[uuid] = payload['state'];
          });

      await sendClosedShiftBacklog(shifts, announcing, (b) async {
        for (final o in b.orders) {
          announcing.markSynced(o.uuid, 1);
        }
        return ShiftFlushResult(merged: true, orderCount: b.orders.length);
      }, outbox: SqliteOutboxStore(db));

      expect(told[peer.uuid], OrderState.synced.name);
      expect(announcing.awaitingSync(anyDevice: true), isEmpty);
    });

    test('a sale the batch left out is not told synced and stays owed', () async {
      final parked = sale(t0.add(const Duration(hours: 16)), device: 'till-2');
      final told = <String>{};
      final announcing = OrderStore(db,
          ownDeviceId: 'till-1',
          publish: (kind, uuid, payload) => told.add(uuid));

      await sendClosedShiftBacklog(shifts, announcing, (b) async {
        for (final o in b.orders.where((o) => o.uuid != parked.uuid)) {
          announcing.markSynced(o.uuid, 1);
        }
        return ShiftFlushResult(merged: true, orderCount: b.orders.length - 1);
      }, outbox: SqliteOutboxStore(db));

      expect(told, isNot(contains(parked.uuid)));
      expect(announcing.awaitingSync(anyDevice: true).map((o) => o.uuid), [parked.uuid]);
    });

    test('a batch the merge declines does not hold back the ones behind it', () async {
      final sent = <String>[];
      await sendClosedShiftBacklog(shifts, orders, (b) async {
        sent.add(b.batchKey);
        if (b.batchKey == first.uuid) {
          return const ShiftFlushResult(
              merged: false, orderCount: 1, skipReason: 'no sales to merge', refused: true);
        }
        return book(b);
      }, outbox: SqliteOutboxStore(db));

      expect(sent, [first.uuid, second.uuid]);
    });

    test('a batch that could not be sent stops the run', () async {
      final sent = <String>[];
      final result = await sendClosedShiftBacklog(shifts, orders, (b) async {
        sent.add(b.batchKey);
        return const ShiftFlushResult(merged: false, orderCount: 0, skipReason: 'offline');
      }, outbox: SqliteOutboxStore(db));

      expect(sent, [first.uuid], reason: 'the next batch would fail the same way');
      expect(result.merged, isFalse);
      expect(result.refused, isFalse);
      expect(orders.awaitingSync(anyDevice: true), hasLength(2));
    });
  });

  group('parked sales', () {
    late SqliteOutboxStore outbox;
    setUp(() => outbox = SqliteOutboxStore(db));
    Set<String> held(Iterable<String> uuids) =>
        outbox.statesOf('order.push', uuids).refused;

    test('a sale held on a server change is left out and stays owed', () async {
      final night = shifts.openShift(openingFloat: 0, cashierId: 'sara', at: t0);
      final parked = sale(t0.add(const Duration(hours: 1)));
      await outbox.append('order.push', parked.uuid, parked.toServerPayload());
      outbox.holdPendingSales('held: server changed');
      final live = sale(t0.add(const Duration(hours: 2)), device: 'till-2');
      shifts.closeShift(countedCash: 0, at: t0.add(const Duration(hours: 6)));

      final sent = <String, List<String>>{};
      await sendClosedShiftBacklog(shifts, orders, (b) async {
        sent[b.batchKey] = [for (final o in b.orders) o.uuid];
        for (final o in b.orders) {
          orders.markSynced(o.uuid, 1);
        }
        return ShiftFlushResult(merged: true, orderCount: b.orders.length);
      }, outbox: outbox);

      expect(sent, {night.uuid: [live.uuid]},
          reason: 'it may carry another server\'s product ids');
      expect(orders.byUuid(parked.uuid)?.state, OrderState.paid);
      expect(held([parked.uuid]), {parked.uuid}, reason: 'still parked for a manager');
    });

    test('a batch the server rejects is parked, not sent again on every retry', () async {
      shifts.openShift(openingFloat: 0, cashierId: 'sara', at: t0);
      final rejected = sale(t0.add(const Duration(hours: 1)));
      shifts.closeShift(countedCash: 0, at: t0.add(const Duration(hours: 6)));
      var sends = 0;
      Future<ShiftFlushResult> reject(ClosedShiftBacklog b) async {
        sends++;
        for (final o in b.orders) {
          await outbox.append('order.push', o.uuid, o.toServerPayload());
        }
        return ShiftFlushResult(
            merged: false,
            orderCount: b.orders.length,
            skipReason: 'unknown product',
            refused: true,
            rejected: true);
      }

      final first = await sendClosedShiftBacklog(shifts, orders, reject, outbox: outbox);
      await sendClosedShiftBacklog(shifts, orders, reject, outbox: outbox);

      expect(first.refused, isTrue);
      expect(sends, 1, reason: 'the server gave its answer; a manager has to act');
      expect(held([rejected.uuid]), {rejected.uuid});
      expect(orders.byUuid(rejected.uuid)?.state, OrderState.paid,
          reason: 'still owed, only parked');
    });

    group('a rejected session revived by a manager', () {
      late Shift night;
      late List<Order> sales;
      late List<List<String>> sent;

      Future<ShiftFlushResult> flush(ClosedShiftBacklog b, {required bool ok}) async {
        sent.add([for (final o in b.orders) o.uuid]);
        for (final o in b.orders) {
          await outbox.append('order.push', o.uuid, o.toServerPayload());
          if (ok) orders.markSynced(o.uuid, 1);
        }
        return ok
            ? ShiftFlushResult(merged: true, orderCount: b.orders.length)
            : ShiftFlushResult(
                merged: false,
                orderCount: b.orders.length,
                skipReason: 'unknown product',
                refused: true,
                rejected: true);
      }

      setUp(() async {
        sent = [];
        night = shifts.openShift(openingFloat: 0, cashierId: 'sara', at: t0);
        sales = [
          sale(t0.add(const Duration(hours: 1))),
          sale(t0.add(const Duration(hours: 2)), device: 'till-2'),
          sale(t0.add(const Duration(hours: 3))),
        ];
        shifts.closeShift(countedCash: 0, at: t0.add(const Duration(hours: 6)));
        await sendClosedShiftBacklog(shifts, orders, (b) => flush(b, ok: false),
            outbox: outbox);
        sent.clear();
      });

      test('goes again whole, as one batch under the night\'s key', () async {
        expect(outbox.heldSessions().single.batchKey, night.uuid);
        expect(outbox.heldSessions().single.count, 3);

        outbox.reviveSession(night.uuid);
        final keys = <String>[];
        await sendClosedShiftBacklog(shifts, orders, (b) {
          keys.add(b.batchKey);
          return flush(b, ok: true);
        }, outbox: outbox);

        expect(keys, [night.uuid]);
        expect(sent, [
          [for (final o in sales) o.uuid]
        ]);
        expect(orders.awaitingSync(anyDevice: true), isEmpty);
      });

      test('is not booked in parts while some of it is still parked', () async {
        // One sale brought back on its own, as a per-sale retry would.
        final one = outbox.dead().firstWhere((e) => e.payloadUuid == sales[1].uuid);
        outbox.revive(one.id);

        await sendClosedShiftBacklog(shifts, orders, (b) => flush(b, ok: true),
            outbox: outbox);

        expect(sent, isEmpty);
        expect(orders.byUuid(sales[1].uuid)?.state, OrderState.paid);
      });
    });

    test('a batch the merge declines is not parked', () async {
      shifts.openShift(openingFloat: 0, cashierId: 'sara', at: t0);
      final declined = sale(t0.add(const Duration(hours: 1)));
      shifts.closeShift(countedCash: 0, at: t0.add(const Duration(hours: 6)));

      await sendClosedShiftBacklog(shifts, orders, (b) async {
        for (final o in b.orders) {
          await outbox.append('order.push', o.uuid, o.toServerPayload());
        }
        return ShiftFlushResult(
            merged: false,
            orderCount: b.orders.length,
            skipReason: 'more than 500 sales queued',
            refused: true);
      }, outbox: outbox);

      expect(held([declined.uuid]), isEmpty,
          reason: 'nothing reached the server, so nothing was answered');
    });

    test('a parked sale in no shift does not become a batch of its own', () async {
      shifts.openShift(openingFloat: 0, cashierId: 'sara', at: t0);
      shifts.closeShift(countedCash: 0, at: t0.add(const Duration(hours: 6)));
      final stray = sale(t0.subtract(const Duration(days: 2)));
      await outbox.append('order.push', stray.uuid, stray.toServerPayload());
      outbox.holdPendingSales('held: server changed');

      expect(nextClosedShiftBacklog(shifts, orders, held: held), isNull);
      expect(nextClosedShiftBacklog(shifts, orders)?.batchKey, 'backlog-${stray.uuid}',
          reason: 'without the check it would be sent');
    });
  });

  group('a session close', () {
    test('tells the shop only the sales its batch booked', () async {
      final store = SqliteOutboxStore(db);
      final told = <String>[];
      final announcing = OrderStore(db,
          ownDeviceId: 'till-1',
          publish: (kind, uuid, payload) {
            if (kind == LanEventKind.orderUpsert) told.add(uuid);
          });
      final booked = sale(t0, device: 'till-2');
      final left = sale(t0.add(const Duration(minutes: 5)), device: 'till-2');
      final outbox = Outbox(store: store, senders: const {});
      final sync = SyncService(
        outbox: outbox,
        catalogue: CatalogueStore(db),
        outboxStore: store,
        audit: AuditLog(db),
        deviceId: 'till-1',
        appVersion: 'test',
        // The server books one of the two and leaves the other out.
        mergeBatch: ({onlyUuids, batchKey}) async {
          announcing.markSynced(booked.uuid, 1);
          return true;
        },
      );

      final result = await bookSessionSales(
          sync, outbox, store, announcing, [booked, left], 'shift-a');

      expect(result.merged, isTrue);
      expect(told, contains(booked.uuid));
      expect(told, isNot(contains(left.uuid)));
      expect(announcing.byUuid(left.uuid)?.state, OrderState.paid,
          reason: 'a sale the batch left out stays owed');
    });

    test('parks the whole batch when the server rejects it', () async {
      final store = SqliteOutboxStore(db);
      final a = sale(t0);
      final b = sale(t0.add(const Duration(minutes: 5)));
      final outbox = Outbox(store: store, senders: const {});
      var sends = 0;
      final sync = SyncService(
        outbox: outbox,
        catalogue: CatalogueStore(db),
        outboxStore: store,
        audit: AuditLog(db),
        deviceId: 'till-1',
        appVersion: 'test',
        mergeBatch: ({onlyUuids, batchKey}) async {
          sends++;
          throw PermanentlyRejected('unknown product');
        },
      );

      final result = await bookSessionSales(
          sync, outbox, store, orders, [a, b], 'shift-a');

      expect(result.rejected, isTrue);
      expect(store.sessionHeldOf([a.uuid, b.uuid]), {a.uuid, b.uuid},
          reason: 'left pending, the retry would send it again');
      expect(store.heldSessions().single.batchKey, 'shift-a');

      final again = await bookSessionSales(
          sync, outbox, store, orders, [a, b], 'shift-a');
      expect(again.held, isTrue);
      expect(again.rejected, isFalse);
      expect(sends, 1, reason: 'a resend without a manager must not reach the server');
      expect(store.sessionHeldOf([a.uuid, b.uuid]), {a.uuid, b.uuid},
          reason: 'a resend without a manager must not revive a parked session');
    });
  });

  group('booking is one write', () {
    late SqliteOutboxStore outbox;
    setUp(() => outbox = SqliteOutboxStore(db));

    BatchPush push(void Function(String uuid) onBooked) => BatchPush(
          outboxStore: outbox,
          send: (uuid, payload) async => {'id': 7, 'name': 'S0007'},
          enabled: () => true,
          batchUuid: () => 'shift-a',
          partnerId: () => 1,
          onOrderBooked: (uuid, [id, name]) {
            onBooked(uuid);
            orders.markSynced(uuid, id);
          },
        );

    Future<List<Order>> queueTwo() async {
      final a = sale(t0);
      final b = sale(t0.add(const Duration(minutes: 5)));
      for (final o in [a, b]) {
        await outbox.append('order.push', o.uuid, o.toServerPayload());
      }
      return [a, b];
    }

    test('an acknowledged batch marks rows sent and sales synced together', () async {
      final sold = await queueTwo();

      expect(await push((_) {}).run(batchKey: 'shift-a'), isTrue);

      expect(outbox.pendingSalesCount, 0);
      for (final o in sold) {
        expect(orders.byUuid(o.uuid)?.state, OrderState.synced);
      }
    });

    test('a failure part way through leaves every row and sale owed', () async {
      final sold = await queueTwo();
      var n = 0;

      await expectLater(
          push((_) {
            if (++n == 2) throw StateError('crash between the writes');
          }).run(batchKey: 'shift-a'),
          throwsStateError);

      expect(outbox.pendingSalesCount, 2, reason: 'rows marked sent for an unbooked night');
      for (final o in sold) {
        expect(orders.byUuid(o.uuid)?.state, OrderState.paid);
      }
    });
  });
}
