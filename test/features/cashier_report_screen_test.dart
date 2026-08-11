import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/reports/cashier_report_screen.dart';

Order _order({required String cashierId, required List<OrderLine> lines}) =>
    Order(
      deviceId: 'till-1',
      cashierId: cashierId,
      lines: lines,
    );

void main() {
  Widget app(List<Order> orders) => MaterialApp(
        home: CashierReportScreen(
          orders: orders,
          formatAmount: (v) => v.toStringAsFixed(2),
        ),
      );

  testWidgets('groups orders by cashier and ranks by total sales descending',
      (tester) async {
    // Sara rings two orders totalling 150, Ali rings one order totalling 40.
    // Sara must therefore rank above Ali in the table.
    final orders = [
      _order(
        cashierId: 'sara',
        lines: [
          OrderLine(productId: 1, name: 'Margherita', quantity: 1, unitPrice: 100),
        ],
      ),
      _order(
        cashierId: 'sara',
        lines: [
          OrderLine(productId: 2, name: 'Water', quantity: 1, unitPrice: 50),
        ],
      ),
      _order(
        cashierId: 'ali',
        lines: [
          OrderLine(productId: 3, name: 'Soda', quantity: 1, unitPrice: 40),
        ],
      ),
    ];

    await tester.pumpWidget(app(orders));

    expect(find.text('Cashier performance'), findsOneWidget);

    // Both cashiers' totals must appear. Ali's 40.00 shows twice (total and
    // average, since a single order's average equals its total), so allow more.
    expect(find.text('150.00'), findsOneWidget);
    expect(find.text('40.00'), findsWidgets);

    // Sara's row must appear above Ali's row, proving the sort-by-total
    // ordering (150 desc before 40) is correct.
    final saraRow = find.byKey(const Key('cashier-row-sara'));
    final aliRow = find.byKey(const Key('cashier-row-ali'));
    expect(saraRow, findsOneWidget);
    expect(aliRow, findsOneWidget);

    final saraTop = tester.getTopLeft(saraRow);
    final aliTop = tester.getTopLeft(aliRow);
    expect(saraTop.dy, lessThan(aliTop.dy));

    // The overall total row sums both cashiers: 150 + 40 = 190, across 3
    // orders.
    final overallRow = find.byKey(const Key('cashier-report-overall-row'));
    expect(overallRow, findsOneWidget);
    expect(find.descendant(of: overallRow, matching: find.text('3')),
        findsOneWidget);
    expect(find.descendant(of: overallRow, matching: find.text('190.00')),
        findsOneWidget);
  });

  testWidgets('shows an empty state when there are no orders', (tester) async {
    await tester.pumpWidget(app(const []));

    expect(find.text('Cashier performance'), findsOneWidget);
    expect(find.text('No orders'), findsOneWidget);
  });
}
