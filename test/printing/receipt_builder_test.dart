import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/printing/receipt_builder.dart';
import 'package:offline_pos/domain/order.dart';

import 'strip_escpos.dart';

String render(
  Order o, {
  int columns = 42,
  bool showDateTime = true,
  bool showNumber = true,
  bool showTable = true,
  bool showPayment = true,
  bool showItemPrice = true,
  String dividerStyle = 'line',
}) {
  final bytes = ReceiptBuilder(
    shopName: 'JOUMA',
    columns: columns,
    footer: 'Thank you',
    showDateTime: showDateTime,
    showNumber: showNumber,
    showTable: showTable,
    showPayment: showPayment,
    showItemPrice: showItemPrice,
    dividerStyle: dividerStyle,
    formatAmount: (v) => v.toStringAsFixed(2),
  ).build(o);
  return strippedText(bytes);
}

Order sample() => Order(deviceId: 'till-1', cashierId: 'sara', lines: [
      OrderLine(productId: 1, name: 'Pizza', quantity: 2, unitPrice: 250, modifiers: [
        OrderModifier(modifierId: 1, name: 'Extra Cheese', quantity: 1, unitPrice: 7),
        OrderModifier(modifierId: 2, name: 'Tomato', quantity: 1, unitPrice: 0),
      ]),
    ]);

void main() {
  test('prints the shop, the cashier and the lines', () {
    final s = render(sample());
    expect(s, contains('JOUMA'));
    expect(s, contains('sara'));
    expect(s, contains('Pizza'));
  });

  test('modifiers are indented under their line', () {
    final s = render(sample());
    expect(s, contains('+ Extra Cheese'));
    final line = s.split('\n').firstWhere((l) => l.contains('Extra Cheese'));
    expect(line.startsWith('   '), isTrue);
  });

  test('a free modifier prints no amount', () {
    final line = render(sample()).split('\n').firstWhere((l) => l.contains('Tomato'));
    expect(line.trimRight(), '   + Tomato');
  });

  test('the total matches the order and scales modifiers by quantity', () {
    // 2 x (250 + 7 + 0)
    expect(sample().total, 514);
    expect(render(sample()), contains('514.00'));
  });

  test('the reference comes from the order uuid, not a server counter', () {
    final o = sample();
    final expected = o.uuid.replaceAll('-', '').substring(0, 6).toUpperCase();
    expect(render(o), contains('#$expected'));
  });

  test('a cash overpayment prints the cash received and the change owed', () {
    // Payment stores the settled amount; the change comes from cashReceived.
    final o = Order(deviceId: 'till-1', cashierId: 'sara')
      ..lines.add(OrderLine(productId: 1, name: 'Cola', quantity: 1, unitPrice: 10))
      ..payments = [const OrderPayment(methodId: 1, amount: 10, label: 'Cash')]
      ..cashReceived = 20;
    final s = render(o);
    expect(s, contains('Received'));
    expect(s, contains('Change'));
    // The change line reads the tendered-minus-due, i.e. 10.00.
    final change = s.split('\n').firstWhere((l) => l.contains('Change'));
    expect(change, contains('10.00'));
  });

  test('a legacy overpayment (tender in the amount, no cashReceived) still shows change', () {
    // Orders from before cash_received existed kept the tendered note in the
    // payment amount. Their reprints must still show the change.
    final o = Order(deviceId: 'till-1', cashierId: 'sara')
      ..lines.add(OrderLine(productId: 1, name: 'Cola', quantity: 1, unitPrice: 10))
      ..payments = [const OrderPayment(methodId: 1, amount: 20, label: 'Cash')];
    final change = render(o).split('\n').firstWhere((l) => l.contains('Change'));
    expect(change, contains('10.00'));
  });

  test('an exact payment prints no change line', () {
    final o = Order(deviceId: 'till-1', cashierId: 'sara')
      ..lines.add(OrderLine(productId: 1, name: 'Cola', quantity: 1, unitPrice: 10))
      ..payments = [const OrderPayment(methodId: 1, amount: 10, label: 'Cash')];
    expect(render(o), isNot(contains('Change')));
  });

  test('narrow paper still ends flush right', () {
    final s = render(sample(), columns: 32);
    final total = s.split('\n').firstWhere((l) => l.contains('TOTAL'));
    expect(total.trimRight().length, 32);
  });

  test('the time of sale prints in local time and can be switched off', () {
    final at = DateTime.utc(2026, 3, 9, 21, 5);
    final o = Order(deviceId: 'till-1', cashierId: 'sara', createdAt: at)
      ..lines.add(OrderLine(productId: 1, name: 'Cola', quantity: 1, unitPrice: 10));
    final local = at.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';

    expect(render(o), contains(stamp));
    expect(render(o, showDateTime: false), isNot(contains(stamp)));
  });

  test('the order number can be switched off without losing the time', () {
    final o = sample();
    final ref = o.uuid.replaceAll('-', '').substring(0, 6).toUpperCase();
    final s = render(o, showNumber: false);
    expect(s, isNot(contains('#$ref')));
    expect(s, contains('${o.createdAt.toLocal().year}-'));
  });

  test('a dine-in table and its covers print on one line', () {
    final o = Order(deviceId: 'till-1', cashierId: 'sara')
      ..tableLabel = 'A3'
      ..guestCount = 4
      ..lines.add(OrderLine(productId: 1, name: 'Cola', quantity: 1, unitPrice: 10));
    expect(render(o), contains('Table A3 - 4 guests'));
    expect(render(o, showTable: false), isNot(contains('Table A3')));
  });

  test('a takeaway with no table prints no table line, toggle or not', () {
    final o = Order(deviceId: 'till-1', cashierId: 'sara', type: OrderType.takeaway)
      ..lines.add(OrderLine(productId: 1, name: 'Cola', quantity: 1, unitPrice: 10));
    expect(render(o), isNot(contains('Table')));
    expect(render(o), isNot(contains('null')));
  });

  test('hiding the payment method keeps the change owed', () {
    final o = Order(deviceId: 'till-1', cashierId: 'sara')
      ..lines.add(OrderLine(productId: 1, name: 'Cola', quantity: 1, unitPrice: 10))
      ..payments = [const OrderPayment(methodId: 1, amount: 10, label: 'Visa')]
      ..cashReceived = 20;
    expect(render(o), contains('Visa'));
    final s = render(o, showPayment: false);
    expect(s, isNot(contains('Visa')));
    expect(s, contains('Change'));
  });

  test('hiding item prices keeps names and quantities but drops the amounts', () {
    final s = render(sample(), showItemPrice: false);
    expect(s, contains('2 x Pizza'));
    expect(s, contains('+ Extra Cheese'));
    // No per-item amount, but the total still prints: the customer still pays.
    expect(s, isNot(contains('500.00')));
    expect(s, contains('514.00'));
  });

  test('the divider style sets the separator character across the paper width', () {
    final stars = render(sample(), dividerStyle: 'stars', columns: 32);
    expect(stars, contains('*' * 32));
    expect(stars, isNot(contains('-' * 32)));
    // An unknown style falls back to a dashed rule rather than printing nothing.
    expect(render(sample(), dividerStyle: 'squiggle'), contains('-' * 42));
  });

  test('a refunded order is banner-marked so it cannot pass as a new sale', () {
    final o = Order(deviceId: 'till-1', cashierId: 'sara', refundOfUuid: 'orig-1')
      ..lines.add(OrderLine(productId: 1, name: 'Cola', quantity: 1, unitPrice: 10));
    final s = render(o);
    expect(s, contains('REFUND'));
    expect(s, contains('TOTAL'));
  });

  test('a deletion slip lists the removed lines, the total removed and the reason', () {
    final o = sample();
    final bytes = ReceiptBuilder(shopName: 'JOUMA', formatAmount: (v) => v.toStringAsFixed(2))
        .buildDeletion(
      o,
      o.lines,
      title: 'ITEM VOIDED',
      at: DateTime.utc(2026, 1, 2, 9, 30),
      actor: 'sara',
      reason: 'wrong table',
    );
    final s = strippedText(bytes);
    expect(s, contains('ITEM VOIDED'));
    expect(s, contains('Pizza'));
    expect(s, contains('REMOVED'));
    // 2 x 250 plus cheese at 7 per unit x 2 = 514 for the line.
    expect(s, contains('514.00'));
    expect(s, contains('wrong table'));
    expect(s, contains('sara'));
  });

  test('a deletion slip nets the removed total against a whole-order discount', () {
    final o = Order(deviceId: 'till-1', cashierId: 'sara', discountPercent: 20)
      ..lines.add(OrderLine(productId: 1, name: 'Cola', quantity: 1, unitPrice: 100));
    final bytes = ReceiptBuilder(shopName: 'JOUMA', formatAmount: (v) => v.toStringAsFixed(2))
        .buildDeletion(o, o.lines, title: 'ITEM VOIDED', at: DateTime.utc(2026, 1, 2));
    final s = strippedText(bytes);
    // Line gross 100, order discount 20% -> customer share removed is 80.
    expect(s, contains('Subtotal'));
    expect(s, contains('Order discount 20%'));
    expect(s, contains('REMOVED'));
    expect(s, contains('80.00'));
  });

  test('a deletion slip never kicks the drawer', () {
    final o = sample();
    final bytes = ReceiptBuilder(shopName: 'JOUMA', formatAmount: (v) => v.toStringAsFixed(2))
        .buildDeletion(o, o.lines, title: 'ORDER CANCELLED', at: DateTime.utc(2026, 1, 2));
    // ESC p (0x1b 0x70) is the drawer-kick sequence; a record slip must not carry it.
    var kicks = false;
    for (var i = 0; i + 1 < bytes.length; i++) {
      if (bytes[i] == 0x1b && bytes[i + 1] == 0x70) kicks = true;
    }
    expect(kicks, isFalse);
  });

  test('the receipt prints the number the customer will quote back', () {
    final order = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      orderNo: '1508-007-A1B',
      lines: [OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 100)],
    );
    expect(render(order), contains('#1508-007-A1B'));
  });

  test('a customer on a counter sale prints on the slip', () {
    final order = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      type: OrderType.takeaway,
      partnerId: 42,
      customerName: 'Nadia',
      lines: [OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 100)],
    );
    expect(render(order), contains('Customer: Nadia'));
  });

  test('a menu in any script still produces a receipt', () {
    // Building a receipt used to throw on a product name outside Latin-1, which
    // for a euro-priced or Arabic menu is every receipt. It threw before the spool
    // had anything to hold, so the sale was taken and nothing anywhere recorded
    // that a receipt had been due.
    final order = Order(deviceId: 'till-1', cashierId: 'sara', lines: [
      OrderLine(productId: 1, name: 'Café — 3€', quantity: 1, unitPrice: 3),
      OrderLine(productId: 2, name: 'شاي', quantity: 1, unitPrice: 2),
    ]);
    final s = render(order);
    expect(s, contains('TOTAL'));
    expect(s, contains('5.00'));
  });

  group('an option that replaced the dish price', () {
    // The sheet the cashier taps quotes the menu price for a size, because that is
    // the figure the customer was given. The receipt used to print the difference
    // from the dish's own price underneath it, so choosing a small coffee showed
    // "Small -5.00" under a header of 20 and neither number was the one quoted.
    Order smallCoffee({double quantity = 1}) =>
        Order(deviceId: 'till-1', cashierId: 'sara', lines: [
          OrderLine(
              productId: 1,
              name: 'Coffee',
              quantity: quantity,
              unitPrice: 20,
              modifiers: [
                OrderModifier(
                    modifierId: 1, name: 'Small', quantity: 1, unitPrice: -5),
              ]),
        ]);

    test('prints the menu price on the item and no amount of its own', () {
      final lines = render(smallCoffee()).split('\n');
      final item = lines.firstWhere((l) => l.contains('Coffee'));
      expect(item, contains('15.00'), reason: 'the price the customer was quoted');
      expect(item, isNot(contains('20.00')));
      expect(lines.firstWhere((l) => l.contains('Small')).trimRight(),
          '   + Small');
    });

    test('never prints a negative under the line', () {
      expect(render(smallCoffee()), isNot(contains('-5.00')));
    });

    test('the printed parts still add up to the total', () {
      // A paid extra on the same line keeps its own amount, so the receipt still
      // reconciles line by line: 2 x 15 folded into the header, plus 2 x 3.
      final o = Order(deviceId: 'till-1', cashierId: 'sara', lines: [
        OrderLine(productId: 1, name: 'Coffee', quantity: 2, unitPrice: 20, modifiers: [
          OrderModifier(modifierId: 1, name: 'Small', quantity: 1, unitPrice: -5),
          OrderModifier(modifierId: 2, name: 'Extra shot', quantity: 1, unitPrice: 3),
        ]),
      ]);
      final lines = render(o).split('\n');
      expect(lines.firstWhere((l) => l.contains('Coffee')), contains('30.00'));
      expect(lines.firstWhere((l) => l.contains('Extra shot')), contains('6.00'));
      expect(o.total, 36);
      expect(render(o), contains('36.00'));
    });
  });
}
