import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/orders/order_history_screen.dart';

void main() {
  testWidgets('lists history tiles for each order', (tester) async {
    final orders = [
      Order(
        deviceId: 'till-1',
        cashierId: 'sara',
        createdAt: DateTime.utc(2026, 8, 6, 12, 30),
        state: OrderState.synced,
        lines: [
          OrderLine(productId: 10, name: 'Margherita', quantity: 1, unitPrice: 250),
        ],
        payments: const [OrderPayment(methodId: 1, amount: 250, label: 'Cash')],
      ),
      Order(
        deviceId: 'till-1',
        cashierId: 'sara',
        createdAt: DateTime.utc(2026, 8, 6, 12, 0),
        state: OrderState.paid,
        lines: [
          OrderLine(productId: 11, name: 'Water', quantity: 2, unitPrice: 10),
        ],
        payments: const [OrderPayment(methodId: 2, amount: 20, label: 'Card')],
      ),
    ];

    await tester.pumpWidget(MaterialApp(
      home: OrderHistoryScreen(
        orders: orders,
        formatAmount: (v) => v.toStringAsFixed(2),
        onReprint: (_) async {},
      ),
    ));

    for (final order in orders) {
      expect(find.byKey(Key('history-${order.uuid}')), findsOneWidget);
    }
  });

  testWidgets('shows an empty state instead of a blank list with no orders',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: OrderHistoryScreen(
        orders: const [],
        formatAmount: (v) => v.toStringAsFixed(2),
        onReprint: (_) async {},
      ),
    ));

    expect(find.text('No orders yet'), findsOneWidget);
  });
}
