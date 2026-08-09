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

  test('a restored draft is not discounted twice', () {
    final o = Order(deviceId: 'd', cashierId: 'c', discountPercent: 20)..lines.add(line(10));
    final back = Order.fromMap(o.toMap());
    expect(back.discountPercent, 20);
    expect(back.subtotal, 10);
    expect(back.total, 8);
  });
}
