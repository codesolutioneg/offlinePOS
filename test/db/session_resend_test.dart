import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
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
}
