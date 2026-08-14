import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/orders/order_history_screen.dart';

void main() {
  Order sale({double servicePercent = 12}) => Order(
        deviceId: 'till-1',
        cashierId: 'sara',
        serviceChargePercent: servicePercent,
        lines: [
          OrderLine(productId: 1, name: 'Pizza', quantity: 2, unitPrice: 100),
        ],
      )..state = OrderState.paid;

  Future<void> open(WidgetTester t, Order o) => t.pumpWidget(MaterialApp(
        home: OrderDetailScreen(
          order: o,
          formatAmount: (v) => v.toStringAsFixed(2),
          onReprint: (_) async {},
        ),
      ));

  testWidgets('a serviced order itemises the service, so the total reconciles',
      (t) async {
    await open(t, sale());
    expect(find.text('Service'), findsOneWidget);
    expect(find.text('24.00'), findsOneWidget);
    expect(find.text('224.00'), findsOneWidget);
  });

  testWidgets('an order with no service charge shows no service row', (t) async {
    await open(t, sale(servicePercent: 0));
    expect(find.text('Service'), findsNothing);
    // The line amount and the total, and nothing between them.
    expect(find.text('200.00'), findsNWidgets(2));
  });
}
