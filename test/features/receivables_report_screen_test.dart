import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/reports/receivables_report_screen.dart';

void main() {
  Order sale({
    required double amount,
    String? customer,
    String label = kOnAccountLabel,
    DateTime? at,
  }) =>
      Order(
        deviceId: 'till-1',
        cashierId: 'sara',
        customerName: customer,
        createdAt: at ?? DateTime.utc(2026, 8, 12, 12),
      )
        ..lines.add(
            OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: amount))
        ..payments = [OrderPayment(methodId: 7, amount: amount, label: label)];

  Widget app(List<Order> orders) => MaterialApp(
        home: ReceivablesReportScreen(
          orders: orders,
          formatAmount: (v) => v.toStringAsFixed(2),
        ),
      );

  testWidgets('a range with nothing on account says so', (t) async {
    await t.pumpWidget(app([sale(amount: 100, customer: 'Nadia', label: 'Cash')]));
    expect(find.byKey(const Key('receivables-empty')), findsOneWidget);
  });

  testWidgets('what each customer owes is totalled, biggest first', (t) async {
    await t.pumpWidget(app([
      sale(amount: 100, customer: 'Nadia'),
      sale(amount: 250, customer: 'Omar'),
      sale(amount: 50, customer: 'Nadia'),
      // Settled at the counter: not a receivable.
      sale(amount: 900, customer: 'Nadia', label: 'Cash'),
    ]));

    final texts = t
        .widgetList<Text>(find.descendant(
            of: find.byKey(const Key('receivables-by-customer')),
            matching: find.byType(Text)))
        .map((w) => w.data)
        .toList();
    expect(texts, containsAllInOrder(['Omar', '250.00', 'Nadia', '150.00']));
    expect(texts, containsAllInOrder(['Total outstanding', '400.00']));
  });

  testWidgets('a split bill only counts the part left on the account', (t) async {
    final part = sale(amount: 200, customer: 'Nadia')
      ..payments = [
        const OrderPayment(methodId: 1, amount: 120, label: 'Cash'),
        const OrderPayment(methodId: 7, amount: 80, label: kOnAccountLabel),
      ];
    await t.pumpWidget(app([part]));

    expect(ReceivablesReportScreen.owedOn(part), 80);
    expect(find.text('80.00'), findsWidgets);
    expect(find.text('200.00'), findsNothing);
  });

  testWidgets('each sale is listed with its number so it can be chased', (t) async {
    final one = sale(amount: 100, customer: 'Nadia');
    await t.pumpWidget(app([one]));
    expect(find.textContaining(one.displayNo), findsOneWidget);
  });
}
