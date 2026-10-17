import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/lan/lan_event.dart';
import 'package:offline_pos/core/sync/batch_merge.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/domain/payload_balance.dart';
import 'package:offline_pos/domain/shift.dart';

import 'sqlite_loader.dart';

/// Shop-wide session resend: every till's tickets in one closed window become
/// one balanced payload, including ones already marked synced after a partial
/// push (manager deleted that SO in Odoo and wants the night sent again).
void main() {
  late Db db;
  late OrderStore orders;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    orders = OrderStore(db, ownDeviceId: 'primary');
  });
  tearDown(() => db.close());

  Order paid({
    required String device,
    required double price,
    required DateTime at,
    OrderState state = OrderState.paid,
  }) {
    final o = Order(
      deviceId: device,
      cashierId: 'sara',
      createdAt: at.toUtc(),
      type: OrderType.takeaway,
    )..lines.add(OrderLine(
        productId: 1,
        odooProductId: 1,
        name: 'Tea',
        quantity: 1,
        unitPrice: price,
        taxRate: 14,
      ));
    o.payments = [OrderPayment(methodId: 1, amount: o.total, label: 'Cash')];
    o.state = state;
    orders.save(o, announce: false);
    return o;
  }

  test('salesInShift anyDevice includes peer tickets already marked synced', () {
    final opened = DateTime.utc(2026, 10, 15, 10);
    final closed = opened.add(const Duration(hours: 8));
    final shift = Shift(
      id: '1',
      openedAt: opened,
      closedAt: closed,
      openingFloat: 0,
      cashierId: 'sara',
    );

    final a = paid(
        device: 'primary',
        price: 100,
        at: opened.add(const Duration(hours: 1)),
        state: OrderState.synced);
    final b = paid(
        device: 'secondary',
        price: 50,
        at: opened.add(const Duration(hours: 2)));

    final mine = orders.awaitingSyncInShift(shift);
    expect(mine, isEmpty, reason: 'own tickets already synced');

    final all = orders.salesInShift(shift, anyDevice: true);
    expect(all.map((o) => o.uuid).toSet(), {a.uuid, b.uuid});
    expect(all.fold<double>(0, (s, o) => s + o.total),
        closeTo(a.total + b.total, 0.02));
  });

  test('merged resend of primary+peer sales still balances payments', () {
    final at = DateTime.utc(2026, 10, 15, 12);
    final a = paid(device: 'primary', price: 100, at: at);
    final b = paid(
        device: 'secondary',
        price: 80,
        at: at.add(const Duration(minutes: 5)));
    OutboxEntry entry(Order o) => OutboxEntry(
          id: o.uuid.hashCode.abs(),
          kind: 'order.push',
          payloadUuid: o.uuid,
          payload: o.toServerPayload(),
        );
    final outcome = mergeOrderPushes(
      [entry(a), entry(b)],
      batchUuid: 'shift-resend',
      partnerId: 42,
      partnerName: 'Session',
    );
    expect(outcome.notMerged, isNull, reason: outcome.notMerged?.reason);
    expect(payloadBalances(outcome.batch!.payload), isTrue);
    expect(outcome.batch!.payload['order_count'], 2);
  });

  test('a fully cancelled sale is not resent — complimentary must not inflate Odoo',
      () {
    final opened = DateTime.utc(2026, 10, 15, 10);
    final closed = opened.add(const Duration(hours: 8));
    final shift = Shift(
      id: '1',
      openedAt: opened,
      closedAt: closed,
      openingFloat: 0,
      cashierId: 'sara',
    );
    final keep = paid(
        device: 'primary',
        price: 100,
        at: opened.add(const Duration(hours: 1)));
    final voided = paid(
        device: 'primary',
        price: 50,
        at: opened.add(const Duration(hours: 2)));
    voided.payments = [
      OrderPayment(methodId: 9, amount: voided.total, label: 'Complimentary')
    ];
    orders.save(voided, announce: false);
    final refund = Order(
      deviceId: 'primary',
      cashierId: 'sara',
      createdAt: opened.add(const Duration(hours: 3)).toUtc(),
      type: OrderType.takeaway,
      refundOfUuid: voided.uuid,
    )..lines.add(OrderLine(
        productId: 1,
        odooProductId: 1,
        name: 'Tea',
        quantity: -1,
        unitPrice: 50,
        taxRate: 14,
      ));
    refund.payments = [
      OrderPayment(methodId: 9, amount: refund.total, label: 'Complimentary')
    ];
    refund.state = OrderState.paid;
    orders.save(refund, announce: false);

    final forOdoo = orders.salesInShift(shift, anyDevice: true);
    expect(forOdoo.map((o) => o.uuid), [keep.uuid]);
    expect(forOdoo.any((o) => o.uuid == voided.uuid), isFalse);
  });

  test('forgetOrderPush clears a sent row so a peer cannot push twice', () async {
    final outbox = SqliteOutboxStore(db);
    const uuid = 'sale-1';
    await outbox.append('order.push', uuid, {'uuid': uuid, 'lines': []});
    final pending = await outbox.pending();
    expect(pending, hasLength(1));
    await outbox.markSent(pending.first.id);
    outbox.forgetOrderPush(uuid);
    expect(await outbox.pending(), isEmpty);
    expect(
        db.raw
            .select(
                "SELECT COUNT(*) c FROM outbox WHERE kind = 'order.push' AND payload_uuid = ?",
                [uuid])
            .first['c'],
        0);
  });

  test('saleUuidsBetween lists every device\'s paid and synced sales in the window',
      () {
    final day = DateTime.utc(2026, 3, 1);
    final mine = paid(device: 'primary', price: 10, at: day.add(const Duration(hours: 9)));
    final theirs = paid(
        device: 'till-b',
        price: 20,
        at: day.add(const Duration(hours: 10)),
        state: OrderState.synced);
    paid(device: 'till-b', price: 30, at: day.add(const Duration(hours: 7)));
    paid(device: 'primary', price: 40, at: day.add(const Duration(hours: 23, minutes: 1)));
    final held = Order(deviceId: 'primary', cashierId: 'sara',
        createdAt: day.add(const Duration(hours: 11)))
      ..state = OrderState.held;
    orders.save(held, announce: false);

    final uuids = orders.saleUuidsBetween(
        day.add(const Duration(hours: 8)), day.add(const Duration(hours: 23)));
    expect(uuids, [mine.uuid, theirs.uuid]);
  });

  test('saleUuidsBetween keeps refunds: a refund is a ticket the other till rang too',
      () {
    final day = DateTime.utc(2026, 3, 1);
    final sale = paid(device: 'till-b', price: 50, at: day.add(const Duration(hours: 9)));
    final refund = Order(
      deviceId: 'till-b',
      cashierId: 'sara',
      createdAt: day.add(const Duration(hours: 10)),
      type: OrderType.takeaway,
    )
      ..refundOfUuid = sale.uuid
      ..lines.add(OrderLine(
          productId: 1, odooProductId: 1, name: 'Tea', quantity: -1, unitPrice: 50,
          taxRate: 14))
      ..state = OrderState.paid;
    orders.save(refund, announce: false);

    final uuids = orders.saleUuidsBetween(day, day.add(const Duration(days: 1)));
    expect(uuids, [sale.uuid, refund.uuid]);
  });

  test('after a booking only the sales it marked synced are told to the shop', () {
    final at = DateTime.utc(2026, 10, 15, 12);
    final booked = paid(device: 'secondary', price: 10, at: at);
    final left = paid(device: 'secondary', price: 20, at: at);
    final told = <String>[];
    final announcing = OrderStore(db,
        ownDeviceId: 'primary',
        publish: (kind, uuid, payload) {
          if (kind == LanEventKind.orderUpsert) told.add(uuid);
        });
    announcing.markSynced(booked.uuid, 1);

    announcing.tellShopBooked([booked.uuid, left.uuid]);

    expect(told, contains(booked.uuid));
    expect(told, isNot(contains(left.uuid)));
    expect(announcing.byUuid(left.uuid)?.state, OrderState.paid,
        reason: 'a sale the batch left out stays owed');
  });

  group('window bounds against stamps of either width', () {
    // Dart writes six fractional digits only when the microseconds are not
    // zero, so a window edge and a sale in the same millisecond can differ in
    // width. As text "…00.000500Z" sorts before "…00.000Z".
    final open = DateTime.utc(2026, 3, 1, 9);
    final close = DateTime.utc(2026, 3, 1, 17, 0, 0, 0, 900);
    Shift shift() => Shift(
        id: '1', openedAt: open, closedAt: close, openingFloat: 0, cashierId: 'sara');

    test('a sale just after the open, in its millisecond, is inside', () {
      final s = paid(
          device: 'till-b',
          price: 10,
          at: open.add(const Duration(microseconds: 500)));
      expect(orders.saleUuidsBetween(open, close), [s.uuid]);
      expect(orders.salesInShift(shift(), anyDevice: true).map((o) => o.uuid),
          [s.uuid]);
      expect(orders.awaitingSyncInShift(shift(), anyDevice: true).map((o) => o.uuid),
          [s.uuid]);
    });

    test('a sale just before the close, in its millisecond, is inside', () {
      final s = paid(device: 'till-b', price: 10, at: DateTime.utc(2026, 3, 1, 17));
      expect(orders.saleUuidsBetween(open, close), [s.uuid]);
      expect(orders.salesInShift(shift(), anyDevice: true).map((o) => o.uuid),
          [s.uuid]);
    });

    test('sales a millisecond outside either end stay out', () {
      paid(
          device: 'till-b',
          price: 10,
          at: open.subtract(const Duration(milliseconds: 1)));
      paid(
          device: 'till-b',
          price: 10,
          at: close.add(const Duration(milliseconds: 1)));
      expect(orders.saleUuidsBetween(open, close), isEmpty);
      expect(orders.salesInShift(shift(), anyDevice: true), isEmpty);
    });

    test('sales a few microseconds outside either end stay out', () {
      final opened = DateTime.utc(2026, 3, 1, 9, 0, 0, 0, 900);
      final closed = DateTime.utc(2026, 3, 1, 17, 0, 0, 0, 900);
      final edges = Shift(
          id: '2',
          openedAt: opened,
          closedAt: closed,
          openingFloat: 0,
          cashierId: 'sara');
      paid(device: 'till-b', price: 10, at: DateTime.utc(2026, 3, 1, 9, 0, 0, 0, 100));
      paid(device: 'till-b', price: 10, at: DateTime.utc(2026, 3, 1, 17, 0, 0, 0, 999));
      expect(orders.saleUuidsBetween(opened, closed), isEmpty);
      expect(orders.salesInShift(edges, anyDevice: true), isEmpty);
      expect(orders.awaitingSyncInShift(edges, anyDevice: true), isEmpty);
    });

    test('sales at the exact open and close are inside', () {
      final opened = DateTime.utc(2026, 3, 1, 9, 0, 0, 0, 900);
      final closed = DateTime.utc(2026, 3, 1, 17, 0, 0, 0, 900);
      final edges = Shift(
          id: '2',
          openedAt: opened,
          closedAt: closed,
          openingFloat: 0,
          cashierId: 'sara');
      final first = paid(device: 'till-b', price: 10, at: opened);
      final last = paid(device: 'till-b', price: 10, at: closed);
      expect(orders.saleUuidsBetween(opened, closed), [first.uuid, last.uuid]);
      expect(orders.salesInShift(edges, anyDevice: true).map((o) => o.uuid),
          [first.uuid, last.uuid]);
      expect(orders.awaitingSyncInShift(edges, anyDevice: true).map((o) => o.uuid),
          [first.uuid, last.uuid]);
    });

    test('stamps written with or without a fraction or zone letter compare by instant',
        () {
      final opened = DateTime.utc(2026, 3, 1, 9, 0, 0, 0, 900);
      final closed = DateTime.utc(2026, 3, 1, 17, 0, 0, 0, 900);
      String stamped(String createdAt) {
        final o = paid(device: 'till-b', price: 10, at: opened);
        db.raw.execute(
            'UPDATE orders SET created_at = ? WHERE uuid = ?', [createdAt, o.uuid]);
        return o.uuid;
      }

      final inside = {
        stamped('2026-03-01T09:00:00.000900'),
        stamped('2026-03-01T09:00:01Z'),
        stamped('2026-03-01T09:00:01'),
        stamped('2026-03-01T12:00:00.000Z'),
        stamped('2026-03-01T17:00:00.000900Z'),
        stamped('2026-03-01T17:00:00.000Z'),
      };
      stamped('2026-03-01T09:00:00Z');
      stamped('2026-03-01T09:00:00.000');
      stamped('2026-03-01T09:00:00.000899Z');
      stamped('2026-03-01T17:00:00.000901');
      stamped('2026-03-01T17:00:00.001Z');
      expect(orders.saleUuidsBetween(opened, closed).toSet(), inside);
    });

    test('a sale rung with a local clock is filed by its instant', () {
      final s = paid(
          device: 'till-b',
          price: 10,
          at: open.add(const Duration(hours: 1)).toLocal());
      expect(orders.saleUuidsBetween(open, close), [s.uuid]);
    });
  });
}
