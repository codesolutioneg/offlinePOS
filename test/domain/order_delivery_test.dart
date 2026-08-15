import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';

/// What a delivery carries for the shop's own use, and what the server is told.
void main() {
  Order delivery() => Order(
        deviceId: 'd',
        cashierId: 'c',
        type: OrderType.delivery,
        deliveryChannel: 'Talabat',
        companyOrderNo: 'TLB-99182',
        driverName: 'Hany',
      )..lines.add(OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 100));

  test('channel, company number and driver survive a write to disk', () {
    final back = Order.fromMap(delivery().toMap());
    expect(back.deliveryChannel, 'Talabat');
    expect(back.companyOrderNo, 'TLB-99182');
    expect(back.driverName, 'Hany');
  });

  test('none of the three travels to the server', () {
    final sent = delivery().toServerPayload();
    expect(sent.containsKey('delivery_channel'), isFalse);
    expect(sent.containsKey('company_order_no'), isFalse);
    expect(sent.containsKey('driver_name'), isFalse);
  });

  test('the wire still calls the sale a delivery', () {
    expect(delivery().toServerPayload()['order_type'], 'delivery');
  });

  test('an order saved before these existed reads back with none of them', () {
    final old = delivery().toMap()
      ..remove('delivery_channel')
      ..remove('company_order_no')
      ..remove('driver_name');
    final back = Order.fromMap(old);
    expect(back.deliveryChannel, isNull);
    expect(back.companyOrderNo, isNull);
    expect(back.driverName, isNull);
  });
}
