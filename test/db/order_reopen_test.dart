import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/domain/order.dart';

import 'sqlite_loader.dart';

/// Reopening a paid sale so it can be corrected before it is booked.
///
/// The rules this file exists to hold: a sale the server already has can never be
/// reopened, and whichever way a reopened sale ends up, the shop books exactly one
/// version of it and never loses the money.
void main() {
  late Db db;
  late OrderStore orders;
  late SqliteOutboxStore outboxStore;
  late Outbox outbox;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    orders = OrderStore(db, ownDeviceId: 'till-1');
    outboxStore = SqliteOutboxStore(db);
    outbox = Outbox(store: outboxStore, senders: {});
  });
  tearDown(() => db.close());

  /// Withdraws the queued push exactly as the till does.
  bool withdraw(String uuid) => outboxStore.withdrawPending('order.push', uuid);

  /// A sale rung and tendered on this till, queued for the shift-close batch.
  Future<Order> paidSale({String device = 'till-1', double price = 250}) async {
    final o = Order(deviceId: device, cashierId: 'sara', lines: [
      OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: price),
    ])..state = OrderState.paid;
    orders.save(o);
    await outbox.enqueue('order.push', o.uuid, o.toServerPayload());
    return o;
  }

  test('a paid sale goes back to a draft the cashier can correct', () async {
    final o = await paidSale();

    expect(orders.reopen(o.uuid, withdrawPush: withdraw), isTrue);

    final back = orders.byUuid(o.uuid)!;
    expect(back.state, OrderState.draft);
    expect(orders.drafts().map((d) => d.uuid), [o.uuid]);
    expect(orders.awaitingSync(), isEmpty);
  });

  test('the queued push is gone, so the pre-edit sale can no longer be booked',
      () async {
    final o = await paidSale();
    expect(outboxStore.pendingSalesCount, 1);

    orders.reopen(o.uuid, withdrawPush: withdraw);

    expect(outboxStore.pendingSalesCount, 0);
    // Nothing is owed to the server while the sale is back on the counter: it is
    // no longer a sale until it is tendered again.
    expect(await outbox.drain(), 0);
  });

  test('a synced sale can never be reopened, whatever the caller asks', () async {
    final o = await paidSale();
    orders.markSynced(o.uuid, 42);

    expect(orders.reopen(o.uuid, withdrawPush: withdraw), isFalse);
    expect(orders.byUuid(o.uuid)!.state, OrderState.synced);
  });

  test('a push that is already acknowledged refuses the reopen and changes nothing',
      () async {
    // The state on the order can lag the queue: the server booked the sale and the
    // acknowledgement was recorded on the row before it reached the order.
    final o = await paidSale();
    await outboxStore.markSent((await outboxStore.pending()).single.id);

    expect(orders.reopen(o.uuid, withdrawPush: withdraw), isFalse);
    expect(orders.byUuid(o.uuid)!.state, OrderState.paid);
    // The row is left exactly as it was found, acknowledged rather than deleted.
    expect(outboxStore.pendingSalesCount, 0);
    expect(outboxStore.deadCount, 0);
  });

  test('a parked push refuses the reopen rather than stranding the sale', () async {
    final o = await paidSale();
    await outboxStore.markDead((await outboxStore.pending()).single.id, 'rejected');

    expect(orders.reopen(o.uuid, withdrawPush: withdraw), isFalse);
    expect(orders.byUuid(o.uuid)!.state, OrderState.paid);
    expect(outboxStore.deadCount, 1);
  });

  test('a refusal to withdraw leaves the order paid and the queue untouched',
      () async {
    // What the till does while a batch push is running: the entries are already
    // read out of the table, so nothing may be taken back from under it.
    final o = await paidSale();

    expect(orders.reopen(o.uuid, withdrawPush: (_) => false), isFalse);
    expect(orders.byUuid(o.uuid)!.state, OrderState.paid);
    expect(outboxStore.pendingSalesCount, 1);
  });

  test('another till\'s sale is not this one\'s to reopen', () async {
    final o = await paidSale(device: 'till-2');

    expect(orders.reopen(o.uuid, withdrawPush: withdraw), isFalse);
    expect(orders.byUuid(o.uuid)!.state, OrderState.paid);
  });

  test('a refund is a reversal, not something to edit back into the cart', () async {
    final refund = Order(deviceId: 'till-1', cashierId: 'sara', lines: [
      OrderLine(productId: 1, name: 'Pizza', quantity: -1, unitPrice: 250),
    ])
      ..state = OrderState.paid
      ..refundOfUuid = 'the-original';
    orders.save(refund);

    expect(orders.reopen(refund.uuid, withdrawPush: withdraw), isFalse);
  });

  test('a held tab and an unknown order are both refused', () {
    final held = Order(deviceId: 'till-1', cashierId: 'sara')
      ..state = OrderState.held;
    orders.save(held);

    expect(orders.reopen(held.uuid, withdrawPush: withdraw), isFalse);
    expect(orders.reopen('never-existed', withdrawPush: withdraw), isFalse);
  });

  test('the tenders come off, so the second payment is not appended to the first',
      () async {
    final o = await paidSale();
    o.payments = const [OrderPayment(methodId: 1, amount: 250, label: 'Cash')];
    o.cashReceived = 300;
    orders.save(o);

    orders.reopen(o.uuid, withdrawPush: withdraw);

    final back = orders.byUuid(o.uuid)!;
    expect(back.payments, isEmpty);
    expect(back.amountPaid, 0);
    expect(back.cashReceived, isNull);
  });

  test('the correction is stamped on the order, so its receipt is marked', () async {
    final o = await paidSale();
    expect(o.amended, isFalse);

    orders.reopen(o.uuid, withdrawPush: withdraw);

    expect(orders.byUuid(o.uuid)!.amended, isTrue);
  });

  test('exactly one version of a corrected sale reaches the server', () async {
    final booked = <Map<String, dynamic>>[];
    final wired = Outbox(store: outboxStore, senders: {
      'order.push': (e) async => booked.add(e.payload),
    });
    final o = await paidSale();

    // Reopened, corrected, tendered again the way the session does it.
    orders.reopen(o.uuid, withdrawPush: withdraw);
    final corrected = orders.byUuid(o.uuid)!
      ..lines.add(OrderLine(productId: 2, name: 'Cola', quantity: 1, unitPrice: 30))
      ..state = OrderState.paid;
    orders.save(corrected);
    await wired.enqueue('order.push', corrected.uuid, corrected.toServerPayload());

    expect(await wired.drain(), 1);
    expect(booked, hasLength(1));
    expect(booked.single['uuid'], o.uuid);
    // The corrected version, not the one that was queued at the first payment.
    expect((booked.single['lines'] as List), hasLength(2));
    expect(outboxStore.pendingSalesCount, 0);
  });

  test('a correction that is abandoned books nothing at all', () async {
    final sent = <String>[];
    final wired = Outbox(store: outboxStore, senders: {
      'order.push': (e) async => sent.add(e.payloadUuid),
    });
    final o = await paidSale();

    // Reopened and then left on the counter: the money was never taken, so there
    // is no sale for the shift-close batch to book.
    orders.reopen(o.uuid, withdrawPush: withdraw);

    expect(await wired.drain(), 0);
    expect(sent, isEmpty);
    // And the sweep that re-queues stranded sales leaves a draft alone.
    expect(orders.awaitingSync(), isEmpty);
  });

  test('a reopened sale keeps its kitchen flags, so the food is not cooked twice',
      () async {
    final o = Order(deviceId: 'till-1', cashierId: 'sara', lines: [
      OrderLine(
        productId: 1,
        name: 'Pizza',
        quantity: 1,
        unitPrice: 250,
        printedToKitchen: true,
        firedStations: ['kitchen'],
      ),
    ])..state = OrderState.paid;
    orders.save(o);
    await outbox.enqueue('order.push', o.uuid, o.toServerPayload());

    orders.reopen(o.uuid, withdrawPush: withdraw);

    final back = orders.byUuid(o.uuid)!;
    expect(back.lines.single.printedToKitchen, isTrue);
    expect(back.lines.single.firedStations, ['kitchen']);
    // The same predicate the till fires on: nothing on this order is due to cook.
    expect(back.lines.where((l) => !l.printedToKitchen), isEmpty);
  });

  test('withdrawing a push that was never queued is not an error', () {
    // A sale whose original enqueue was lost (killed between saving and queuing)
    // must still be correctable rather than stuck.
    final o = Order(deviceId: 'till-1', cashierId: 'sara', lines: [
      OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 250),
    ])..state = OrderState.paid;
    orders.save(o);

    expect(orders.reopen(o.uuid, withdrawPush: withdraw), isTrue);
    expect(orders.byUuid(o.uuid)!.state, OrderState.draft);
  });

  test('withdrawing one sale leaves the rest of the queue in order', () async {
    final a = await paidSale();
    final b = await paidSale();
    final c = await paidSale();

    orders.reopen(b.uuid, withdrawPush: withdraw);

    expect((await outboxStore.pending()).map((e) => e.payloadUuid),
        [a.uuid, c.uuid]);
  });
}
