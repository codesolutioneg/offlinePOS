import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/reports/top_products_report_screen.dart';

Order _order({required List<OrderLine> lines}) => Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      lines: lines,
    );

void main() {
  Widget app(List<Order> orders) => MaterialApp(
        home: TopProductsReportScreen(
          orders: orders,
          formatAmount: (v) => v.toStringAsFixed(2),
        ),
      );

  testWidgets('shows empty state when there are no orders', (tester) async {
    await tester.pumpWidget(app(const []));

    expect(find.text('Top products'), findsOneWidget);
    expect(find.text('No orders'), findsOneWidget);
  });

  testWidgets('ranks the top item by revenue first even though it sells fewer units',
      (tester) async {
    // Margherita: 1 unit at 200 = 200 revenue (wins by revenue).
    // Soda: 10 units at 5 each = 50 revenue (wins by quantity).
    final orders = [
      _order(lines: [
        OrderLine(productId: 1, name: 'Margherita', quantity: 1, unitPrice: 200),
        OrderLine(productId: 2, name: 'Soda', quantity: 4, unitPrice: 5),
      ]),
      _order(lines: [
        OrderLine(productId: 2, name: 'Soda', quantity: 6, unitPrice: 5),
      ]),
    ];

    await tester.pumpWidget(app(orders));

    final byRevenue = find.byKey(const Key('top-by-revenue'));
    final byQty = find.byKey(const Key('top-by-qty'));
    expect(byRevenue, findsOneWidget);
    expect(byQty, findsOneWidget);

    // Margherita (higher revenue, fewer units) renders first in the revenue list.
    final revenueNames = tester.widgetList<Text>(
      find.descendant(of: byRevenue, matching: find.byType(Text)),
    );
    expect(revenueNames.first.data, 'Margherita');

    // Soda (higher unit count) renders first in the quantity list.
    final qtyNames = tester.widgetList<Text>(
      find.descendant(of: byQty, matching: find.byType(Text)),
    );
    expect(qtyNames.first.data, 'Soda');

    // The same amounts appear in both the revenue and quantity lists, so allow
    // more than one match.
    expect(find.text('200.00'), findsWidgets);
    expect(find.text('50.00'), findsWidgets);
    expect(find.byIcon(Icons.star), findsNWidgets(2));
  });
}
