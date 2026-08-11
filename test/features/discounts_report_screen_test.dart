import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/reports/discounts_report_screen.dart';

Order _order({
  required List<OrderLine> lines,
  double discountPercent = 0,
  String? discountReason,
}) =>
    Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      lines: lines,
      discountPercent: discountPercent,
      discountReason: discountReason,
    );

void main() {
  Widget app(List<Order> orders) => MaterialApp(
        home: DiscountsReportScreen(
          orders: orders,
          formatAmount: (v) => v.toStringAsFixed(2),
        ),
      );

  testWidgets('shows the empty state when no order has a discount',
      (tester) async {
    final orders = [
      _order(lines: [OrderLine(productId: 1, name: 'Water', quantity: 1, unitPrice: 10)]),
    ];

    await tester.pumpWidget(app(orders));

    expect(find.text('Discounts'), findsOneWidget);
    expect(find.byKey(const Key('discounts-empty-state')), findsOneWidget);
    expect(find.text('No discounts given'), findsOneWidget);
  });

  testWidgets(
      'sums order-level and line-level discounts and groups reasons by amount',
      (tester) async {
    // Order A: subtotal 100 (line has its own 10% off, gross 100 -> total 90),
    // then a 20% whole-order discount on top, reason 'Manager comp'.
    // Line-level discount: 100 * 10% = 10.
    // Order-level discount: subtotal (90) * 20% = 18.
    final orderA = _order(
      lines: [
        OrderLine(
          productId: 1,
          name: 'Margherita',
          quantity: 1,
          unitPrice: 100,
          discountPercent: 10,
        ),
      ],
      discountPercent: 20,
      discountReason: 'Manager comp',
    );

    // Order B: subtotal 50, no line discount, 10% whole-order discount, same
    // reason as order A -> reasons should combine to 2 orders.
    // Order-level discount: 50 * 10% = 5.
    final orderB = _order(
      lines: [OrderLine(productId: 2, name: 'Soda', quantity: 1, unitPrice: 50)],
      discountPercent: 10,
      discountReason: 'Manager comp',
    );

    // Order C: 15% whole-order discount with no reason recorded, should fall
    // back to 'No reason' and rank below 'Manager comp' (23 > 15).
    // Order-level discount: 100 * 15% = 15.
    final orderC = _order(
      lines: [OrderLine(productId: 3, name: 'Pizza', quantity: 1, unitPrice: 100)],
      discountPercent: 15,
    );

    // Order D: no discount at all, should not count as a discounted order.
    final orderD = _order(
      lines: [OrderLine(productId: 4, name: 'Water', quantity: 1, unitPrice: 10)],
    );

    await tester.pumpWidget(app([orderA, orderB, orderC, orderD]));

    expect(find.text('Discounts'), findsOneWidget);
    expect(find.byKey(const Key('discounts-empty-state')), findsNothing);

    // 4 orders total, 3 of them discounted (A, B, C).
    expect(find.text('4'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);

    // Total discount given = order-level (18 + 5 + 15 = 38) + line-level (10) = 48.
    expect(find.text('48.00'), findsOneWidget);
    expect(find.text('38.00'), findsOneWidget);
    expect(find.text('10.00'), findsOneWidget);

    // 'Manager comp' combines A and B into 2 orders for 23.00 (18 + 5).
    final reasonsList = find.byKey(const Key('discount-reasons-list'));
    expect(reasonsList, findsOneWidget);
    expect(find.descendant(of: reasonsList, matching: find.text('Manager comp')),
        findsOneWidget);
    expect(find.descendant(of: reasonsList, matching: find.text('2 orders')),
        findsOneWidget);
    expect(find.descendant(of: reasonsList, matching: find.text('23.00')),
        findsOneWidget);

    // 'No reason' holds order C alone, at 15.00.
    expect(find.descendant(of: reasonsList, matching: find.text('No reason')),
        findsOneWidget);
    expect(find.descendant(of: reasonsList, matching: find.text('1 order')),
        findsOneWidget);
    expect(find.descendant(of: reasonsList, matching: find.text('15.00')),
        findsOneWidget);

    // 'Manager comp' (23) must rank above 'No reason' (15).
    final managerTop = tester.getTopLeft(
        find.descendant(of: reasonsList, matching: find.text('Manager comp')));
    final noReasonTop = tester.getTopLeft(
        find.descendant(of: reasonsList, matching: find.text('No reason')));
    expect(managerTop.dy, lessThan(noReasonTop.dy));
  });
}
