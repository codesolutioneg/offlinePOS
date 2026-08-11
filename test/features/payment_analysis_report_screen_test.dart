import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/reports/payment_analysis_report_screen.dart';

Order _order({required List<OrderPayment> payments, List<OrderLine>? lines}) => Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      lines: lines ?? [OrderLine(productId: 1, name: 'Margherita', quantity: 1, unitPrice: 100)],
      payments: payments,
    );

void main() {
  Widget app(List<Order> orders) => MaterialApp(
        home: PaymentAnalysisReportScreen(
          orders: orders,
          formatAmount: (v) => v.toStringAsFixed(2),
        ),
      );

  testWidgets('shows empty state when there are no orders', (tester) async {
    await tester.pumpWidget(app(const []));

    expect(find.text('Payment analysis'), findsOneWidget);
    expect(find.text('No orders'), findsOneWidget);
  });

  testWidgets('renders a mix of cash, card, and unrecorded (cash fallback) orders',
      (tester) async {
    // Card: 150 across one split-tender order (card 100 + card 50).
    // Cash: labelled cash payment of 30, plus a 200 order with no payments at
    // all, which the report must still book to cash for its full total.
    final orders = [
      _order(
        lines: [OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 150)],
        payments: const [
          OrderPayment(methodId: 2, amount: 100, label: 'Card'),
          OrderPayment(methodId: 2, amount: 50, label: 'Card'),
        ],
      ),
      _order(
        lines: [OrderLine(productId: 2, name: 'Soda', quantity: 1, unitPrice: 30)],
        payments: const [OrderPayment(methodId: 1, amount: 30, label: 'Cash')],
      ),
      _order(
        lines: [OrderLine(productId: 3, name: 'Burger', quantity: 1, unitPrice: 200)],
        payments: const [],
      ),
    ];

    await tester.pumpWidget(app(orders));

    final list = find.byKey(const Key('payment-analysis-list'));
    expect(list, findsOneWidget);

    // Card wins the ranking at 150 over cash's combined 230 (30 + 200)... no,
    // cash (30 + 200 = 230) actually leads, so it renders first and bold.
    final labels = tester.widgetList<Text>(
      find.descendant(of: list, matching: find.byType(Text)),
    );
    expect(labels.first.data, 'Cash');

    expect(find.text('Card'), findsOneWidget);
    expect(find.text('Cash'), findsOneWidget);
    expect(find.text('230.00'), findsOneWidget);
    expect(find.text('150.00'), findsOneWidget);
    expect(find.text('Grand total'), findsOneWidget);
    expect(find.text('380.00'), findsOneWidget);
    expect(find.byIcon(Icons.star), findsOneWidget);
  });
}
