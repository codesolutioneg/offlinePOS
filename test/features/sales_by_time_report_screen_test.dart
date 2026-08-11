import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/reports/sales_by_time_report_screen.dart';

Order _orderAtLocalHour(int hour, {required List<OrderLine> lines}) {
  // createdAt is stored/compared in UTC, so build the known local hour first
  // and convert to UTC for the constructor: this pins the bucket the screen
  // must show regardless of the machine's own timezone.
  final now = DateTime.now();
  final local = DateTime(now.year, now.month, now.day, hour);
  return Order(
    deviceId: 'till-1',
    cashierId: 'sara',
    createdAt: local.toUtc(),
    lines: lines,
  );
}

void main() {
  Widget app(List<Order> orders) => MaterialApp(
        home: SalesByTimeReportScreen(
          orders: orders,
          formatAmount: (v) => v.toStringAsFixed(2),
        ),
      );

  testWidgets('shows empty state when there are no orders', (tester) async {
    await tester.pumpWidget(app(const []));

    expect(find.text('Sales by hour'), findsOneWidget);
    expect(find.text('No orders'), findsOneWidget);
  });

  testWidgets('buckets orders by local hour and renders the busy hour total',
      (tester) async {
    // Hour 12 (lunch rush) gets two orders totalling 150. Hour 9 (a quiet
    // morning order) gets one order totalling 20. Hour 12 must clearly be
    // the busier hour.
    final orders = [
      _orderAtLocalHour(12,
          lines: [OrderLine(productId: 1, name: 'Margherita', quantity: 1, unitPrice: 100)]),
      _orderAtLocalHour(12,
          lines: [OrderLine(productId: 2, name: 'Soda', quantity: 1, unitPrice: 50)]),
      _orderAtLocalHour(9,
          lines: [OrderLine(productId: 3, name: 'Coffee', quantity: 1, unitPrice: 20)]),
    ];

    await tester.pumpWidget(app(orders));

    expect(find.text('Sales by hour'), findsOneWidget);

    // The busy hour (12:00) shows 2 orders and its 150 total.
    expect(find.text('12:00'), findsOneWidget);
    expect(find.text('09:00'), findsOneWidget);
    expect(find.text('150.00'), findsOneWidget);
    expect(find.text('20.00'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);

    // The peak-hour marker only appears once, next to the busy hour.
    expect(find.byIcon(Icons.trending_up), findsOneWidget);

    // The 12:00 bar (peak) must be visibly wider than the 09:00 bar, proving
    // the proportional-width bars actually differ, not just the numbers.
    // Rows render chronologically (09:00 before 12:00), so the quiet hour is
    // the first bar and the peak hour is the second.
    final hourList = find.byKey(const Key('hourly-sales-list'));
    expect(hourList, findsOneWidget);
    final quietBarSize = tester.getSize(find
        .descendant(of: hourList, matching: find.byType(FractionallySizedBox))
        .at(0));
    final peakBarSize = tester.getSize(find
        .descendant(of: hourList, matching: find.byType(FractionallySizedBox))
        .at(1));
    expect(peakBarSize.width, greaterThan(quietBarSize.width));
  });
}
