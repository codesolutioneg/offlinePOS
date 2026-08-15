import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/reports/period_comparison_report_screen.dart';

void main() {
  Order sale(double amount) => Order(
        deviceId: 'd',
        cashierId: 'sara',
        type: OrderType.takeaway,
      )..lines.add(OrderLine(
          productId: 1, name: 'Pizza', quantity: 1, unitPrice: amount));

  Widget screen(List<Order> current, List<Order> previous) => MaterialApp(
        home: PeriodComparisonReportScreen(
          current: current,
          previous: previous,
          currentLabel: 'Today',
          previousLabel: 'Previous period',
          formatAmount: (v) => v.toStringAsFixed(2),
        ),
      );

  testWidgets('growth against the earlier period is shown per measure', (t) async {
    await t.pumpWidget(screen([sale(100), sale(100)], [sale(100)]));

    expect(find.byKey(const Key('comparison-periods')), findsOneWidget);
    // Orders doubled, gross doubled, average ticket flat.
    expect(find.text('+100%'), findsNWidgets(2));
    expect(find.text('='), findsWidgets);
  });

  testWidgets('a fall reads as a negative percentage', (t) async {
    await t.pumpWidget(screen([sale(50)], [sale(100)]));
    expect(find.text('-50%'), findsWidgets);
  });

  testWidgets('with no earlier period nothing is invented', (t) async {
    await t.pumpWidget(screen([sale(100)], const []));

    expect(find.text('Nothing was sold in the earlier period.'), findsOneWidget);
    expect(find.text('new'), findsWidgets);
    expect(find.textContaining('%'), findsNothing);
  });

  testWidgets('two empty periods still render', (t) async {
    await t.pumpWidget(screen(const [], const []));
    final rows = t.widget<Column>(find.byKey(const Key('comparison-rows')));
    expect(rows.children.length, 5);
    expect(find.text('='), findsNWidgets(5));
  });
}
