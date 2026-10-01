import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/reports/flash/flash_report_data.dart';

Order _paid({
  required String uuid,
  required String deviceId,
  required String cashierId,
  required OrderType type,
  required double price,
  String? payLabel,
}) {
  return Order(
    uuid: uuid,
    deviceId: deviceId,
    cashierId: cashierId,
    type: type,
    lines: [
      OrderLine(
          productId: 1, name: 'Item', quantity: 1, unitPrice: price, taxRate: 14),
    ],
    payments: [
      OrderPayment(methodId: -1, amount: price * 1.14, label: payLabel ?? 'Cash'),
    ],
  )..state = OrderState.paid;
}

void main() {
  test('shop flash sums every till', () {
    final orders = [
      _paid(
          uuid: 'a',
          deviceId: 'till-1',
          cashierId: 'sara',
          type: OrderType.dineIn,
          price: 100),
      _paid(
          uuid: 'b',
          deviceId: 'till-2',
          cashierId: 'mona',
          type: OrderType.storeDelivery,
          price: 50,
          payLabel: 'Visa'),
    ];
    final flash = FlashReportBuilder.build(
      title: 'Flash Collector',
      periodLabel: 'Today',
      orders: orders,
    );
    expect(flash.ordersCount, 2);
    expect(flash.byDevice.keys, containsAll(['till-1', 'till-2']));
    expect(flash.byPaymentMethod['Cash'], closeTo(114, 0.01));
    expect(flash.byPaymentMethod['Visa'], closeTo(57, 0.01));
  });

  test('deliveryOnly keeps delivery channels', () {
    final orders = [
      _paid(
          uuid: 'a',
          deviceId: 't1',
          cashierId: 'c1',
          type: OrderType.dineIn,
          price: 10),
      _paid(
          uuid: 'b',
          deviceId: 't1',
          cashierId: 'c1',
          type: OrderType.storeDelivery,
          price: 20),
    ];
    expect(FlashReportBuilder.deliveryOnly(orders), hasLength(1));
  });
}
