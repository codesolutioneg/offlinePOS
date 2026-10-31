import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';

import '../db/sqlite_loader.dart';
import 'shop.dart';

/// A till that skipped a sale another till already took the money for (a re-join
/// clears its open tabs and keeps only what it had) gets it back by reading every
/// log again, and nothing it already holds goes backwards.
void main() {
  setUpAll(useSystemSqlite);

  late TestShop shop;
  setUp(() => shop = TestShop());
  tearDown(() => shop.close());

  test('a paid sale this till lost comes back on a read from the start', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();

    final sale = heldOrder('till-a', table: '1');
    a.orders.save(sale);
    await shop.settle();
    sale
      ..state = OrderState.paid
      ..payments = [const OrderPayment(methodId: 1, amount: 100)];
    a.orders.save(sale);
    await shop.settle();
    expect(b.orders.byUuid(sale.uuid)!.state, OrderState.paid);

    b.db.raw.execute('DELETE FROM orders WHERE uuid = ?', [sale.uuid]);
    await shop.settle();
    expect(b.orders.byUuid(sale.uuid), isNull,
        reason: 'the cursor is past it, so an ordinary pass never asks again');

    b.log.resetCursors();
    await shop.settle();
    expect(b.orders.byUuid(sale.uuid)!.state, OrderState.paid);
    expect(b.orders.heldAnywhere(), isEmpty);
  });

  test('a tab discarded on its till stays discarded after a read from the start',
      () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();

    final tab = heldOrder('till-a', table: '4');
    a.orders.save(tab);
    await shop.settle();
    a.orders.delete(tab.uuid);
    await shop.settle();
    expect(b.orders.byUuid(tab.uuid), isNull);

    b.log.resetCursors();
    await shop.settle();
    expect(b.orders.byUuid(tab.uuid), isNull);
    expect(b.orders.occupyingAnywhere(), isEmpty);
  });

  test('reading again from the start changes nothing that is already right',
      () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();

    final open = heldOrder('till-a', table: '2');
    final paid = heldOrder('till-a', table: '3');
    a.orders.save(open);
    a.orders.save(paid);
    await shop.settle();
    paid
      ..state = OrderState.paid
      ..payments = [const OrderPayment(methodId: 1, amount: 100)];
    a.orders.save(paid);
    await shop.settle();

    b.log.resetCursors();
    await shop.settle();

    expect(b.orders.byUuid(open.uuid)!.state, OrderState.held);
    expect(b.orders.byUuid(paid.uuid)!.state, OrderState.paid);
    expect(b.orders.heldAnywhere().map((o) => o.uuid), [open.uuid]);
  });
}
