import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';

void main() {
  OrderLine line(double p, [double q = 1]) =>
      OrderLine(productId: 1, name: 'x', quantity: q, unitPrice: p);

  test('discount reduces total and is folded into the server payload only', () {
    final o = Order(deviceId: 'd', cashierId: 'c', discountPercent: 10)..lines.add(line(100));
    expect(o.subtotal, 100);
    expect(o.total, 90);
    expect((o.toMap()['lines'][0]['unit_price'] as num), 100); // raw stays full
    expect(o.toMap()['discount_percent'], 10);
    expect((o.toServerPayload()['lines'][0]['unit_price'] as num), 90); // discounted for Odoo
  });

  test('customer and payments are carried in the payload', () {
    final o = Order(deviceId: 'd', cashierId: 'c', partnerId: 7, customerName: 'Nour')
      ..lines.add(line(50))
      ..payments = [const OrderPayment(methodId: 2, amount: 50)];
    final m = o.toMap();
    expect(m['partner_id'], 7);
    expect(m['customer_name'], 'Nour');
    expect((m['payments'] as List).first['method_id'], 2);
  });

  test('a cash overpayment books the settled amount, not the note tendered', () {
    // The customer pays 20 for a 10 sale. Revenue is 10; the extra 10 is change, so
    // the payment stores 10 and the cash received rides its own field for the
    // receipt. This keeps the drawer, the payment mix and Odoo from over-counting.
    final o = Order(deviceId: 'd', cashierId: 'c')
      ..lines.add(line(10))
      ..payments = [const OrderPayment(methodId: 1, amount: 10)]
      ..cashReceived = 20;
    expect(o.total, 10);
    expect((o.toMap()['payments'] as List).first['amount'], 10);
    expect(o.toMap()['cash_received'], 20);
    expect(Order.fromMap(o.toMap()).cashReceived, 20);
  });

  test('a locally-created customer never leaks its synthetic id as partner_id', () {
    final o = Order(deviceId: 'd', cashierId: 'c', partnerId: -123, customerName: 'Ali')
      ..lines.add(line(5));
    expect(o.toMap()['partner_id'], -123); // local persistence keeps the link
    expect(o.toServerPayload()['partner_id'], isNull); // never sent to Odoo
    expect(o.toServerPayload()['customer_name'], 'Ali'); // the name still travels
  });

  test('a real Odoo partner id is sent through unchanged', () {
    final o = Order(deviceId: 'd', cashierId: 'c', partnerId: 42)..lines.add(line(5));
    expect(o.toServerPayload()['partner_id'], 42);
  });

  test('a restored draft is not discounted twice', () {
    final o = Order(deviceId: 'd', cashierId: 'c', discountPercent: 20)..lines.add(line(10));
    final back = Order.fromMap(o.toMap());
    expect(back.discountPercent, 20);
    expect(back.subtotal, 10);
    expect(back.total, 8);
  });
}
