import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';

/// Money off, expressed as the percentage the rest of the app understands.
void main() {
  test('an amount becomes the percentage it takes off the base', () {
    expect(discountPercentForAmount(25, 100), 25);
    expect(discountPercentForAmount(5, 40), 12.5);
  });

  test('more than the bill gives the bill away, never more', () {
    expect(discountPercentForAmount(500, 100), 100);
  });

  test('nothing typed, or nothing to discount, gives nothing away', () {
    expect(discountPercentForAmount(0, 100), 0);
    expect(discountPercentForAmount(-10, 100), 0);
    expect(discountPercentForAmount(10, 0), 0);
  });

  test('the converted percentage prices the order the cashier expected', () {
    final order = Order(deviceId: 'd', cashierId: 'c')
      ..lines.add(OrderLine(productId: 1, name: 'Pizza', quantity: 2, unitPrice: 60));
    order.discountPercent = discountPercentForAmount(30, order.subtotal);
    expect(order.total, 90);
  });
}
