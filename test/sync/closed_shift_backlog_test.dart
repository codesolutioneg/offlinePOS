import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/shift_store.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/sync/batch_push.dart';
import 'package:offline_pos/core/sync/closed_shift_backlog.dart';
import 'package:offline_pos/domain/order.dart';

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

  Order sale(DateTime at) {
    final o = Order(
      deviceId: 'till-1',
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
