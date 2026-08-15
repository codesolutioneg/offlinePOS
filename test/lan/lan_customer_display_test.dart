import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/lan/lan_cart_board.dart';
import 'package:offline_pos/domain/order.dart';

import '../db/sqlite_loader.dart';
import 'shop.dart';

/// The counter, as a display bolted to the front of it reads it.
void main() {
  setUpAll(useSystemSqlite);

  late TestShop shop;
  setUp(() => shop = TestShop());
  tearDown(() => shop.close());

  /// A cart being rung on [till]: a draft, which is the one thing the fabric did
  /// not carry before a display existed.
  Order ringUp(TestTill till, {String item = 'Pizza', double price = 100}) {
    final order = Order(deviceId: till.deviceId, cashierId: 'sara')
      ..lines.add(OrderLine(productId: 1, name: item, quantity: 1, unitPrice: price));
    till.orders.save(order);
    return order;
  }

  test('a till that feeds no display shares nothing about its counter', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();

    ringUp(a);
    await shop.settle();

    // Exactly the pre-display behaviour: a draft is the till's own working state.
    expect(LanCartBoard(b.settings).showing(), isNull);
    expect(a.log.count, 0);
  });

  test('with a display on, the cart reaches it as it is rung', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();
    LanCartBoard(a.settings).publishing = true;

    ringUp(a, item: 'Pizza', price: 100);
    await shop.settle();

    final cart = LanCartBoard(b.settings).showing()!;
    expect(cart.deviceId, 'till-a');
    expect(cart.lines.single.name, 'Pizza');
    expect(cart.lines.single.quantity, 1);
    expect(cart.total, 100);
  });

  test('taking the money clears the display', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();
    LanCartBoard(a.settings).publishing = true;

    final order = ringUp(a);
    await shop.settle();
    expect(LanCartBoard(b.settings).showing()!.isEmpty, isFalse);

    order.state = OrderState.paid;
    a.orders.save(order);
    await shop.settle();

    // Cleared rather than left up: the next customer in the queue must not read the
    // last one's shopping.
    expect(LanCartBoard(b.settings).showing()!.isEmpty, isTrue);
    expect(LanCartBoard(b.settings).showing()!.total, 0);
  });

  test('a cart is a snapshot, so a shift of taps is one row in the log', () async {
    final a = shop.add('till-a');
    shop.add('till-b');
    shop.introduceAll();
    LanCartBoard(a.settings).publishing = true;

    final order = ringUp(a);
    for (var i = 0; i < 20; i++) {
      order.lines.first.quantity += 1;
      a.orders.save(order);
    }

    // One row for the counter, however many times it changed: the log holds the
    // latest picture and nothing else, so a busy till cannot fill the disk with
    // carts nobody will ever read.
    expect(a.log.count, 1);
  });

  test('the display keeps up with the newest cart after superseding', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();
    LanCartBoard(a.settings).publishing = true;

    final order = ringUp(a, item: 'Pizza');
    await shop.settle();
    order.lines.add(OrderLine(productId: 2, name: 'Cola', quantity: 2, unitPrice: 30));
    a.orders.save(order);
    await shop.settle();

    final cart = LanCartBoard(b.settings).showing()!;
    expect(cart.lines.map((l) => l.name), ['Pizza', 'Cola']);
    expect(cart.total, 160);
  });

  test('a cart never becomes an order on the device showing it', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();
    LanCartBoard(a.settings).publishing = true;

    ringUp(a);
    await shop.settle();

    // The display device holds a picture, not a sale: nothing to recall, nothing to
    // report, nothing to push.
    expect(b.orders.count, 0);
    expect(b.outboxStore.pendingCount, 0);
  });

  test('a display can be pointed at one counter and stays there', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    final c = shop.add('till-c');
    shop.introduceAll();
    LanCartBoard(a.settings).publishing = true;
    LanCartBoard(b.settings).publishing = true;

    ringUp(a, item: 'Pizza');
    ringUp(b, item: 'Beer');
    await shop.settle();

    final board = LanCartBoard(c.settings);
    board.source = 'till-a';
    expect(board.showing()!.lines.single.name, 'Pizza');
    board.source = 'till-b';
    expect(board.showing()!.lines.single.name, 'Beer');
    // Unpinned, it follows whichever counter moved last.
    board.source = null;
    expect(board.showing(), isNotNull);
  });
}
