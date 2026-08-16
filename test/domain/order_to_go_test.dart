import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';

/// A to-go sale: the till's own kind of order, booked as the takeaway the server
/// already understands.
void main() {
  Order toGo() => Order(
        deviceId: 'till-1',
        cashierId: 'sara',
        type: OrderType.toGo,
        tableLabel: '5',
        lines: [OrderLine(productId: 10, name: 'Margherita', quantity: 1, unitPrice: 250)],
      );

  test('it is its own type on the till and a takeaway on the wire', () {
    final o = toGo();

    expect(o.toMap()['order_type'], 'toGo');
    expect(o.toServerPayload()['order_type'], 'takeaway');
  });

  test('it survives a round trip through the local store', () {
    final restored = Order.fromMap(toGo().toMap());

    expect(restored.type, OrderType.toGo);
    expect(restored.tableLabel, '5');
  });

  test('every other type still goes over the wire as itself', () {
    for (final type in OrderType.values.where((t) => t != OrderType.toGo)) {
      final o = Order(deviceId: 'till-1', cashierId: 'sara', type: type);
      expect(o.toServerPayload()['order_type'], type.name);
    }
  });

  test('a to-go and a dine-in are the two that can sit at a table', () {
    expect(OrderType.toGo.seatsAtTable, isTrue);
    expect(OrderType.dineIn.seatsAtTable, isTrue);
    expect(OrderType.takeaway.seatsAtTable, isFalse);
    expect(OrderType.delivery.seatsAtTable, isFalse);
  });
}
