import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';

/// How a discount reaches Odoo.
///
/// Folding it into the prices books the right money but hands Odoo a cheaper item
/// rather than a discount, which is why a shop cannot find its discounts there.
/// Both ways of saying it are checked here, and in both the sale must still total
/// exactly what the customer paid.
void main() {
  OrderLine line(double price, {double qty = 1, double off = 0}) => OrderLine(
      productId: 1, name: 'Pizza', quantity: qty, unitPrice: price,
      discountPercent: off);

  /// What Odoo will make of the lines: quantity times price, modifiers included
  /// the way the module expands them.
  double serverTotal(Map<String, dynamic> payload) {
    var total = 0.0;
    for (final raw in payload['lines'] as List) {
      final l = raw as Map;
      final qty = (l['quantity'] as num).toDouble();
      total += qty * (l['unit_price'] as num).toDouble();
      for (final rawMod in (l['modifiers'] as List? ?? const [])) {
        final m = rawMod as Map;
        total += qty *
            (m['quantity'] as num).toDouble() *
            (m['unit_price'] as num).toDouble();
      }
    }
    return total;
  }

  tearDown(() => DiscountBooking.productId = null);

  test('the payload says what was taken off, even with it folded into the prices',
      () {
    final o = Order(deviceId: 'd', cashierId: 'c', discountPercent: 10)
      ..lines.add(line(100));
    final p = o.toServerPayload();

    expect(p['discount_amount'], 10,
        reason: 'without this the payload says nothing about a discount at all, '
            'and nothing on the Odoo side can report on one');
    expect(p['prices_include_discount'], isTrue,
        reason: 'the prices are already net, and only saying so makes applying '
            'the amount a second time impossible');
    // Unchanged: the percentage stays zeroed and the price stays folded.
    expect(p['discount_percent'], 0);
    expect((p['lines'][0]['unit_price'] as num), 90);
    expect(serverTotal(p), o.total);
  });

  test('a line discount counts towards the amount too', () {
    final o = Order(deviceId: 'd', cashierId: 'c')..lines.add(line(100, off: 25));
    expect(o.toServerPayload()['discount_amount'], 25);
  });

  test('a sale with no discount says zero rather than nothing', () {
    final o = Order(deviceId: 'd', cashierId: 'c')..lines.add(line(100));
    expect(o.toServerPayload()['discount_amount'], 0);
  });

  test('with a discount product the prices come back up and the discount is a line',
      () {
    DiscountBooking.productId = 55;
    final o = Order(deviceId: 'd', cashierId: 'c', discountPercent: 10)
      ..lines.add(line(100, qty: 2));
    final p = o.toServerPayload();
    final lines = p['lines'] as List;

    expect(lines, hasLength(2));
    expect((lines[0]['unit_price'] as num), 100,
        reason: 'Odoo should show the menu price, not a price nobody quoted');
    expect(lines[1]['product_id'], 55);
    expect((lines[1]['unit_price'] as num), -20);
    expect(lines[1]['quantity'], 1);
    expect(p['prices_include_discount'], isFalse);
    // The whole point: the customer paid the same either way.
    expect(serverTotal(p), o.total);
  });

  test('both discounts leave the prices together', () {
    DiscountBooking.productId = 55;
    // 100 off 20% on the line, then 10% off the bill: 100 -> 80 -> 72.
    final o = Order(deviceId: 'd', cashierId: 'c', discountPercent: 10)
      ..lines.add(line(100, off: 20));
    final p = o.toServerPayload();
    expect((p['lines'][0]['unit_price'] as num), 100);
    expect((p['lines'][1]['unit_price'] as num), -28);
    expect(serverTotal(p), closeTo(72, 0.001));
    expect(o.total, closeTo(72, 0.001));
  });

  test('the service charge still rides in the prices, discount line or not', () {
    DiscountBooking.productId = 55;
    // 10% service on a 100 bill discounted 10%: food 90, service 9, total 99.
    final o = Order(
        deviceId: 'd', cashierId: 'c', discountPercent: 10, serviceChargePercent: 10)
      ..lines.add(line(100));
    final p = o.toServerPayload();
    expect((p['lines'][0]['unit_price'] as num), closeTo(110, 0.001),
        reason: 'the service is taxed at the item rate, so it stays in the price');
    expect((p['lines'][1]['unit_price'] as num), closeTo(-11, 0.001));
    expect(serverTotal(p), closeTo(o.total, 0.001));
  });

  test('a modifier is discounted with the line it belongs to', () {
    DiscountBooking.productId = 55;
    final o = Order(deviceId: 'd', cashierId: 'c', discountPercent: 50)
      ..lines.add(line(100, qty: 2)
        ..modifiers.add(OrderModifier(
            modifierId: 1, name: 'Cheese', quantity: 1, unitPrice: 10,
            productId: 9)));
    final p = o.toServerPayload();
    expect((p['lines'][0]['modifiers'][0]['unit_price'] as num), 10);
    expect((p['lines'][1]['unit_price'] as num), -110);
    expect(serverTotal(p), o.total);
  });

  test('a refund hands the discount back instead of giving it again', () {
    DiscountBooking.productId = 55;
    final o = Order(deviceId: 'd', cashierId: 'c', discountPercent: 10,
        refundOfUuid: 'the-sale')
      ..lines.add(line(100, qty: -1));
    final p = o.toServerPayload();
    expect((p['lines'][1]['unit_price'] as num), 10,
        reason: 'a credit note gives back the discounted amount, not the full one');
    expect(serverTotal(p), o.total);
  });

  test('nothing given away adds no line', () {
    DiscountBooking.productId = 55;
    final o = Order(deviceId: 'd', cashierId: 'c')..lines.add(line(100));
    expect((o.toServerPayload()['lines'] as List), hasLength(1));
  });
}
