import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/sync/batch_merge.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/domain/payload_balance.dart';

/// Merging a shift into one sales order, and every case where it declines to.
///
/// The merge is the one place on this till where several sales become one
/// document, so it is also the one place where a sale can go missing without
/// anything failing. Each refusal below is a case where sending one payload would
/// lose something, and refusing leaves the ordinary per-sale push to do it right.
void main() {
  var next = 0;

  OutboxEntry entryFor(Order o) {
    final payload = o.toServerPayload();
    return OutboxEntry(
      id: ++next,
      kind: 'order.push',
      payloadUuid: o.uuid,
      payload: payload,
    );
  }

  Order paidSale({
    double price = 100,
    double delivery = 0,
    double tip = 0,
    String cashier = 'sara',
    int methodId = 1,
    DateTime? at,
  }) {
    final o = Order(
      deviceId: 'till-1',
      cashierId: cashier,
      createdAt: at,
      type: delivery > 0 ? OrderType.delivery : OrderType.dineIn,
      deliveryCost: delivery,
      tip: tip,
    )..lines.add(
        OrderLine(productId: 10, odooProductId: 10, name: 'Pizza', quantity: 1, unitPrice: price));
    o.payments = [OrderPayment(methodId: methodId, amount: o.total, label: 'Cash')];
    o.state = OrderState.paid;
    return o;
  }

  test('two sales become one payload keyed on the shift', () {
    final a = paidSale(at: DateTime.utc(2026, 3, 1, 19));
    final b = paidSale(price: 250, at: DateTime.utc(2026, 3, 1, 21));
    final batch = mergeOrderPushes([entryFor(a), entryFor(b)],
            batchUuid: 'shift-uuid-1')
        .batch!;

    expect(batch.uuid, 'shift-uuid-1');
    expect(batch.payload['uuid'], 'shift-uuid-1');
    expect(batch.payload['order_count'], 2);
    expect(batch.orderUuids, [a.uuid, b.uuid]);
    expect(batch.entryIds, hasLength(2));
    // The earliest ticket dates the document, so a batch cannot post before the
    // first sale in it happened.
    expect(batch.payload['created_at'], DateTime.utc(2026, 3, 1, 19).toIso8601String());
    expect(batch.payload['amount_total'], closeTo(350, 0.01));
    expect(payloadBalances(batch.payload), isTrue);
  });

  test('every line still says which sale it came from', () {
    final a = paidSale();
    final b = paidSale(price: 250);
    final batch =
        mergeOrderPushes([entryFor(a), entryFor(b)], batchUuid: 'shift').batch!;

    final lines = (batch.payload['lines'] as List).cast<Map>();
    expect(lines.map((l) => l['order_uuid']).toList(), [a.uuid, b.uuid]);
    // Not aggregated by product: two sales of the same dish stay two lines, or
    // the document can no longer say what any one ticket was.
    expect(lines, hasLength(2));
  });

  test('each ticket keeps its own header, without repeating its lines', () {
    final a = paidSale(cashier: 'sara');
    final b = paidSale(cashier: 'omar');
    final batch =
        mergeOrderPushes([entryFor(a), entryFor(b)], batchUuid: 'shift').batch!;

    final tickets = (batch.payload['orders'] as List).cast<Map>();
    expect(tickets.map((o) => o['cashier_id']).toList(), ['sara', 'omar']);
    expect(tickets.every((o) => o.containsKey('lines')), isFalse,
        reason: 'the lines are in the batch already, tagged with this uuid');
    expect(tickets.every((o) => o.containsKey('business_date')), isTrue);
  });

  test('tenders are summed per method, and the money still adds up', () {
    final cash = paidSale(price: 100);
    final alsoCash = paidSale(price: 250);
    final card = paidSale(price: 40, methodId: 2);
    final batch = mergeOrderPushes(
            [entryFor(cash), entryFor(alsoCash), entryFor(card)],
            batchUuid: 'shift')
        .batch!;

    final payments = (batch.payload['payments'] as List).cast<Map>();
    expect(payments, hasLength(2));
    expect(payments.firstWhere((p) => p['method_id'] == 1)['amount'], closeTo(350, 0.01));
    expect(payments.firstWhere((p) => p['method_id'] == 2)['amount'], closeTo(40, 0.01));
    expect(payloadBalances(batch.payload), isTrue);
  });

  test('delivery charges and tips are summed and still declared', () {
    final a = paidSale(delivery: 25, tip: 10);
    final b = paidSale(delivery: 30);
    final batch =
        mergeOrderPushes([entryFor(a), entryFor(b)], batchUuid: 'shift').batch!;

    expect(batch.payload['delivery_cost'], closeTo(55, 0.01));
    expect(batch.payload['tip'], closeTo(10, 0.01));
    expect(payloadBalances(batch.payload), isTrue,
        reason: payloadImbalanceReason(batch.payload) ?? '');
  });

  test('one trading day travels; two do not', () {
    final monday = paidSale(at: DateTime.utc(2026, 3, 2, 19));
    final tuesday = paidSale(at: DateTime.utc(2026, 3, 3, 19));
    final sameDay = mergeOrderPushes(
            [entryFor(monday), entryFor(paidSale(at: DateTime.utc(2026, 3, 2, 21)))],
            batchUuid: 'shift')
        .batch!;
    expect(sameDay.payload['business_date'], isNotNull);

    final spanning =
        mergeOrderPushes([entryFor(monday), entryFor(tuesday)], batchUuid: 'shift')
            .batch!;
    // Rather than posting two days onto whichever came first. Each ticket keeps
    // its own below.
    expect(spanning.payload.containsKey('business_date'), isFalse);
    expect(
        (spanning.payload['orders'] as List)
            .map((o) => (o as Map)['business_date'])
            .toSet(),
        hasLength(2));
  });

  test('a refund is left to go out on its own', () {
    final sale = paidSale();
    final other = paidSale(price: 250);
    final refund = paidSale()..refundOfUuid = sale.uuid;
    final batch = mergeOrderPushes(
            [entryFor(sale), entryFor(other), entryFor(refund)],
            batchUuid: 'shift')
        .batch!;

    expect(batch.payload['order_count'], 2);
    expect(batch.orderUuids, isNot(contains(refund.uuid)));
    expect(batch.entryIds, hasLength(2),
        reason: 'the refund row must stay queued for the ordinary drain');
  });

  test('one sale is not merged: it is already its own payload', () {
    final outcome = mergeOrderPushes([entryFor(paidSale())], batchUuid: 'shift');
    expect(outcome.batch, isNull);
    expect(outcome.notMerged!.reason, contains('fewer than two'));
  });

  test('a batch that states its discount two ways is not merged', () {
    final withoutProduct = entryFor(paidSale());
    DiscountBooking.productId = 900;
    addTearDown(() => DiscountBooking.productId = null);
    final withProduct = entryFor(paidSale(price: 250));

    final outcome =
        mergeOrderPushes([withoutProduct, withProduct], batchUuid: 'shift');
    expect(outcome.batch, isNull);
    expect(outcome.notMerged!.reason, contains('two different ways'));
  });

  test('anything that is not a sale is left alone', () {
    final heartbeat = OutboxEntry(
        id: 99, kind: 'device.status', payloadUuid: 'till-1', payload: const {});
    final outcome = mergeOrderPushes(
        [entryFor(paidSale()), entryFor(paidSale()), heartbeat],
        batchUuid: 'shift');
    expect(outcome.batch!.entryIds, isNot(contains(99)));
  });

  test('a batch that does not add up is not sent', () {
    final good = entryFor(paidSale());
    final broken = entryFor(paidSale());
    // A member whose payments outrun its lines: merged, the whole night would
    // settle for more than it sold.
    (broken.payload['payments'] as List).add({'method_id': 1, 'amount': 50.0});

    final outcome = mergeOrderPushes([good, broken], batchUuid: 'shift');
    expect(outcome.batch, isNull);
    expect(outcome.notMerged!.reason, contains('does not add up'));
  });

  test('the same shift merges to the same key every time', () {
    final a = paidSale();
    final b = paidSale(price: 250);
    final first = mergeOrderPushes([entryFor(a), entryFor(b)], batchUuid: 'shift-9');
    final again = mergeOrderPushes([entryFor(a), entryFor(b)], batchUuid: 'shift-9');
    // The whole recovery story: a retry after a timeout is the same batch under
    // the same key, not a second night.
    expect(first.batch!.uuid, again.batch!.uuid);
  });
}
