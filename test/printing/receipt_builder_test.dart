import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/printing/receipt_builder.dart';
import 'package:offline_pos/domain/order.dart';

import 'strip_escpos.dart';

String render(Order o, {int columns = 42}) {
  final bytes = ReceiptBuilder(
    shopName: 'JOUMA',
    columns: columns,
    footer: 'Thank you',
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

  test('narrow paper still ends flush right', () {
    final s = render(sample(), columns: 32);
    final total = s.split('\n').firstWhere((l) => l.contains('TOTAL'));
    expect(total.trimRight().length, 32);
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
}
