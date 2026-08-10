import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/reports/sales_report_screen.dart';

Order _order({
  required List<OrderLine> lines,
  List<OrderPayment> payments = const [],
  OrderType type = OrderType.dineIn,
}) =>
    Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      type: type,
      lines: lines,
      payments: payments,
    );

void main() {
  Widget app(List<Order> orders) => MaterialApp(
        home: SalesReportScreen(
          orders: orders,
          formatAmount: (v) => v.toStringAsFixed(2),
        ),
      );

  testWidgets('aggregates item sales across orders and ranks by revenue',
      (tester) async {
    // Margherita sells across two orders (150 total revenue) and should
    // outrank Water (20 revenue), which only appears once.
    final orders = [
      _order(
        lines: [
          OrderLine(productId: 10, name: 'Margherita', quantity: 1, unitPrice: 100),
          OrderLine(productId: 11, name: 'Water', quantity: 2, unitPrice: 10),
        ],
        payments: const [OrderPayment(methodId: 1, amount: 120, label: 'Cash')],
      ),
      _order(
        lines: [
          OrderLine(productId: 10, name: 'Margherita', quantity: 1, unitPrice: 50),
        ],
        payments: const [OrderPayment(methodId: 2, amount: 50, label: 'Card')],
        type: OrderType.takeaway,
      ),
      _order(
        lines: [
          OrderLine(productId: 12, name: 'Soda', quantity: 1, unitPrice: 5),
        ],
        payments: const [OrderPayment(methodId: 1, amount: 5)],
      ),
    ];

    await tester.pumpWidget(app(orders));

    expect(find.text('Sales report'), findsOneWidget);
    expect(find.text('Orders'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);

    // Margherita (revenue 150) must appear before Water (revenue 20) in the
    // item-sales list, proving the sort-by-revenue aggregation is correct.
    final itemList = find.byKey(const Key('item-sales-list'));
    expect(itemList, findsOneWidget);
    expect(find.descendant(of: itemList, matching: find.text('2 x Margherita')),
        findsOneWidget);
    expect(find.descendant(of: itemList, matching: find.text('2 x Water')),
        findsOneWidget);

    final margheritaTop = tester.getTopLeft(
        find.descendant(of: itemList, matching: find.text('2 x Margherita')));
    final waterTop = tester.getTopLeft(
        find.descendant(of: itemList, matching: find.text('2 x Water')));
    expect(margheritaTop.dy, lessThan(waterTop.dy));

    // A payment with no label falls back to Cash, so Cash absorbs both the
    // labelled cash payment and the unlabelled one.
    expect(find.text('Cash'), findsOneWidget);
    expect(find.text('Card'), findsOneWidget);
  });
}
