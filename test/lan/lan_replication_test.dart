import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/schema.dart';
import 'package:offline_pos/core/db/table_store.dart';
import 'package:offline_pos/domain/order.dart';

import '../db/sqlite_loader.dart';
import 'shop.dart';

void main() {
  setUpAll(useSystemSqlite);

  late TestShop shop;
  setUp(() => shop = TestShop());
  tearDown(() => shop.close());

  test('two tills converge on the orders each other parked', () async {
    final a = shop.add('till-a', name: 'Front');
    final b = shop.add('till-b', name: 'Bar');
    shop.introduceAll();

    final onA = heldOrder('till-a', table: '5', item: 'Pizza');
    final onB = heldOrder('till-b', table: '9', item: 'Beer');
    a.orders.save(onA);
    b.orders.save(onB);
    await shop.settle();

    // Each till still owns only what it rang, which is what keeps the books
    // straight, but both can see the whole floor.
    expect(a.orders.held().map((o) => o.uuid), [onA.uuid]);
    expect(b.orders.held().map((o) => o.uuid), [onB.uuid]);
    expect(a.orders.heldAnywhere().map((o) => o.uuid).toSet(),
        {onA.uuid, onB.uuid});
    expect(b.orders.heldAnywhere().map((o) => o.uuid).toSet(),
        {onA.uuid, onB.uuid});
    // The payload crossed intact, not just the row.
    expect(b.orders.byUuid(onA.uuid)!.lines.single.name, 'Pizza');
    expect(b.orders.byUuid(onA.uuid)!.tableLabel, '5');
  });

  test('a peer tab occupies the floor without becoming recallable here', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();

    final tab = heldOrder('till-a', table: '5');
    a.orders.save(tab);
    await shop.settle();

    // What the floor plan colours: the table is busy on till B's screen too, so a
    // second cashier cannot seat the same table.
    expect(b.orders.heldAnywhere().map((o) => o.tableLabel), ['5']);
    // What the floor plan refuses: till B cannot recall or settle it, because the
    // till that opened a tab is the one that books it.
    expect(b.orders.held(), isEmpty);
    expect(b.orders.heldElsewhere().map((o) => o.uuid), [tab.uuid]);
  });

  test('a table cancelled on one till stops occupying the other floor', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();

    final tab = heldOrder('till-a', table: '5');
    a.orders.save(tab);
    await shop.settle();
    expect(b.orders.heldAnywhere(), hasLength(1));

    a.orders.delete(tab.uuid);
    await shop.settle();
    expect(b.orders.heldAnywhere(), isEmpty,
        reason: 'a discarded tab must not sit on another floor plan forever');
  });

  test('a partition heals by uuid, with no duplicate orders', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();

    // The switch dies. Till A keeps selling, which is the whole point of the app.
    shop.unreachable.add('till-b');
    final first = heldOrder('till-a', table: '1');
    final second = heldOrder('till-a', table: '2');
    a.orders.save(first);
    a.orders.save(second);
    // A held tab gets added to twice more while B cannot be reached.
    first.lines.add(OrderLine(productId: 2, name: 'Salad', quantity: 1, unitPrice: 40));
    a.orders.save(first);
    await shop.settle();
    expect(b.orders.heldAnywhere(), isEmpty);
    expect(a.errors, isNotEmpty, reason: 'a dead peer is recorded, not hidden');

    // The switch comes back.
    shop.unreachable.remove('till-b');
    await shop.settle();
    expect(b.orders.heldAnywhere(), hasLength(2));
    expect(b.orders.byUuid(first.uuid)!.lines, hasLength(2));

    // Replaying the whole log from scratch is a no-op: every event is an upsert on
    // a uuid, so a peer that lost its cursor converges instead of duplicating.
    b.log.setCursor('till-a', 0);
    await shop.settle();
    expect(b.orders.heldAnywhere(), hasLength(2));
    expect(b.orders.count, 2);
  });

  test('a replicated paid order never enters the receiving till outbox', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();

    final sale = heldOrder('till-a')
      ..state = OrderState.paid
      ..payments = [const OrderPayment(methodId: 1, amount: 100)];
    a.orders.save(sale);
    await shop.settle();

    // It is on B, so the kitchen and the floor can see it.
    expect(b.orders.byUuid(sale.uuid)!.state, OrderState.paid);
    // But B has nothing to send: only the till that took the money books it. The
    // reconcile sweep the sync service runs reads awaitingSync, which is scoped to
    // this till, so there is no path from a replica to an enqueue.
    expect(b.orders.awaitingSync(), isEmpty);
    await b.fabric.pass();
    expect(b.outboxStore.pendingCount, 0);
    // The originating till still owes the server the sale.
    expect(a.orders.awaitingSync().single.uuid, sale.uuid);
  });

  test('kitchen status rings on a till, bumps on the kitchen screen', () async {
    final a = shop.add('till-a', name: 'Front');
    final kds = shop.add('kds-1', name: 'Kitchen');
    shop.introduceAll();

    final ticket = heldOrder('till-a', item: 'Steak');
    a.orders.save(ticket);
    await shop.settle();

    // The board on a device that rings up nothing still shows the ticket.
    expect(kds.orders.kitchenTickets().map((o) => o.uuid), [ticket.uuid]);

    // A cook bumps it. The status lands back on the till that owns the sale.
    kds.orders.setKitchenStatus(ticket.uuid, KitchenStatus.ready);
    await shop.settle();
    expect(a.orders.byUuid(ticket.uuid)!.kitchenStatus, KitchenStatus.ready);

    // And served takes it off the board on both devices.
    kds.orders.setKitchenStatus(ticket.uuid, KitchenStatus.served);
    await shop.settle();
    expect(a.orders.kitchenTickets(), isEmpty);
    expect(kds.orders.kitchenTickets(), isEmpty);
  });

  test('a peer on another schema version is refused, not applied', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    // B announces itself mid-rollout, one version ahead. It never hears of A, so
    // everything that reaches A here is A's own decision to make.
    a.peers.seen(shop.peerFor(b, schemaVersion: Schema.version + 1));

    expect(a.peers.active, isEmpty, reason: 'an incompatible peer never joins');
    expect(a.peers.refused.single.deviceId, 'till-b');
    expect(a.refusals.any((r) => r.startsWith('lan.peer.refused')), isTrue);

    final onB = heldOrder('till-b');
    b.orders.save(onB);
    await shop.settle();
    // A never pulls from a peer it refused.
    expect(a.orders.byUuid(onB.uuid), isNull);

    // Nor does it accept one that pushes to it directly.
    final status = shop.notifyOnSchema(
        'till-b', shop.peerFor(a), b.log.since(0), Schema.version + 1);
    expect(status, 409);
    expect(a.orders.byUuid(onB.uuid), isNull);
    expect(a.refusals.where((r) => r.startsWith('lan.peer.refused')), hasLength(2));
  });

  test('the floor plan laid out on one device reaches the others', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();

    final table = a.tables.add(name: '12', section: 'Terrace', seats: 6);
    await shop.settle();
    expect(b.tables.byId(table.id)!.name, '12');
    expect(b.tables.byId(table.id)!.section, 'Terrace');
    expect(b.tables.byId(table.id)!.seats, 6);

    // A move, and then a removal.
    a.tables.upsert(table.copyWith(x: 3, y: 4, shape: TableShape.round));
    await shop.settle();
    expect(b.tables.byId(table.id)!.x, 3);
    expect(b.tables.byId(table.id)!.shape, TableShape.round);

    a.tables.remove(table.id);
    await shop.settle();
    expect(b.tables.byId(table.id), isNull);
  });

  test('a paid order never loses to a held one, whatever the clocks say', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();

    final sale = heldOrder('till-a');
    a.orders.save(sale);
    await shop.settle();

    // The tab is settled on A. B is told, then told again by a stale event that
    // still describes it as held (a re-sent page after a long partition).
    final stale = b.log.since(0);
    sale.state = OrderState.paid;
    a.orders.save(sale);
    await shop.settle();
    expect(b.orders.byUuid(sale.uuid)!.state, OrderState.paid);

    b.applier.applyAll('till-a', a.log.since(0));
    expect(b.orders.byUuid(sale.uuid)!.state, OrderState.paid,
        reason: 'state only moves forward');
    expect(stale, isEmpty, reason: 'B originates nothing of its own here');
  });
}
