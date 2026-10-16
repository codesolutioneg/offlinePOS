import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/domain/session_close_check.dart';
import 'package:offline_pos/domain/shift.dart';

Order _paid({
  required String uuid,
  required double price,
  String payLabel = 'Cash',
  String deviceId = 'till-1',
}) {
  return Order(
    uuid: uuid,
    deviceId: deviceId,
    cashierId: 'sara',
    type: OrderType.dineIn,
    lines: [
      OrderLine(
          productId: 1, name: 'Item', quantity: 1, unitPrice: price, taxRate: 0),
    ],
    payments: [
      OrderPayment(methodId: -1, amount: price, label: payLabel),
    ],
  )..state = OrderState.paid;
}

ShiftSummary _summaryFrom(List<Order> orders) {
  final mix = paymentMixOf(orders);
  return ShiftSummary(
    openingFloat: 0,
    cashIn: 0,
    cashOut: 0,
    salesCount: orders.length,
    salesTotal: orders.fold(0.0, (s, o) => s + o.total),
    cashSales: mix['Cash'] ?? 0,
    tenders: [
      for (final e in mix.entries)
        TenderTotal(
          label: e.key,
          amount: e.value,
          isCash: e.key.toLowerCase() == 'cash',
        ),
    ],
  );
}

void main() {
  test('full shop set matches the screen', () {
    final shop = [
      _paid(uuid: 'a', price: 100, deviceId: 'till-1'),
      _paid(uuid: 'b', price: 50, payLabel: 'Visa', deviceId: 'till-2'),
    ];
    final match = matchSessionClose(
      screen: _summaryFrom(shop),
      sendOrders: shop,
    );
    expect(match.ok, isTrue);
    expect(match.lines, isEmpty);
  });

  test('own-till-only send fails against the shop screen', () {
    final shop = [
      _paid(uuid: 'a', price: 100, deviceId: 'till-1'),
      _paid(uuid: 'b', price: 50, payLabel: 'Visa', deviceId: 'till-2'),
    ];
    final mine = [shop.first];
    final match = matchSessionClose(
      screen: _summaryFrom(shop),
      sendOrders: mine,
    );
    expect(match.ok, isFalse);
    expect(match.screenCount, 2);
    expect(match.sendCount, 1);
    expect(match.lines, isNotEmpty);
  });

  test('tender mix mismatch is reported', () {
    final screenOrders = [
      _paid(uuid: 'a', price: 100, payLabel: 'Cash'),
    ];
    final sendOrders = [
      _paid(uuid: 'a', price: 100, payLabel: 'Visa'),
    ];
    final match = matchSessionClose(
      screen: _summaryFrom(screenOrders),
      sendOrders: sendOrders,
    );
    expect(match.ok, isFalse);
    expect(match.tenderGaps, isNotEmpty);
  });
}
