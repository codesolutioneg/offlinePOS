import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/delivery.dart';
import 'package:offline_pos/domain/delivery_bulletin.dart';
import 'package:offline_pos/domain/order.dart';

void main() {
  Order bag(OrderType type, {double price = 100, String? driver}) => Order(
        deviceId: 'till-1',
        cashierId: 'sara',
        type: type,
      )
        ..driverId = driver
        ..lines.add(OrderLine(
            productId: 1, name: 'Pizza', quantity: 1, unitPrice: price));

  test('counts only deliveries, by kind, driver and status', () {
    final a = bag(OrderType.storeDelivery);
    final b = bag(OrderType.carDelivery, driver: 'd1')
      ..deliveryStatus = DeliveryStatus.onTheWay;
    final c = bag(OrderType.deliveryFromCompany);
    final table = bag(OrderType.dineIn);
    final paid = bag(OrderType.storeDelivery, price: 50);
    final b0 = DeliveryBulletin.from(
      held: [a, b, c, table, a],
      closedToday: [paid, bag(OrderType.takeaway)],
    );
    expect(b0.waiting, 3);
    expect(b0.store, 1);
    expect(b0.car, 1);
    expect(b0.company, 1);
    expect(b0.noDriver, 1, reason: 'a company bag needs no driver of ours');
    expect(b0.onTheWay, 1);
    expect(b0.waitingAmount, 300);
    expect(b0.closedToday, 1);
    expect(b0.salesToday, 50);
    expect(b0.values((v) => v.toStringAsFixed(0))['sales'], '50');
  });
}
