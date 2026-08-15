import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/shift_store.dart';
import 'package:offline_pos/domain/shift.dart';
import 'package:offline_pos/features/reports/expenses_report_screen.dart';

void main() {
  ShiftMovement out(double amount, String category, String reason,
          {String cashier = 'sara'}) =>
      ShiftMovement(
        movement: CashMovement(
            type: 'out',
            amount: amount,
            reason: reason,
            category: category,
            at: DateTime.now().toUtc()),
        shiftId: 'SH1',
        cashierId: cashier,
      );

  Widget screen(List<ShiftMovement> movements) => MaterialApp(
        home: ExpensesReportScreen(
          movements: movements,
          formatAmount: (v) => v.toStringAsFixed(2),
        ),
      );

  testWidgets('an empty range says so instead of showing a broken report',
      (t) async {
    await t.pumpWidget(screen(const []));
    expect(find.byKey(const Key('expenses-empty-state')), findsOneWidget);
  });

  testWidgets('paid-ins alone are still not expenses', (t) async {
    await t.pumpWidget(screen([
      ShiftMovement(
        movement: CashMovement(
            type: 'in', amount: 100, reason: 'Top-up', at: DateTime.now().toUtc()),
        shiftId: 'SH1',
        cashierId: 'sara',
      ),
    ]));
    expect(find.byKey(const Key('expenses-empty-state')), findsOneWidget);
  });

  testWidgets('payouts total and group by category', (t) async {
    await t.pumpWidget(screen([
      out(20, 'Transport', 'Taxi'),
      out(30, 'Transport', 'Delivery van'),
      out(15, 'Food', 'Staff lunch'),
    ]));

    expect(find.text('65.00'), findsWidgets);
    // Transport is the costliest bucket, so it leads its card.
    final categories = t.widget<Column>(find.byKey(const Key('expenses-by-category')));
    expect(categories.children.length, 2);
    expect(find.text('50.00'), findsOneWidget);
    expect(find.text('Taxi'), findsOneWidget);
  });

  testWidgets('a payout with no category is bucketed, never dropped', (t) async {
    await t.pumpWidget(screen([
      ShiftMovement(
        movement: CashMovement(
            type: 'out', amount: 9, reason: '', at: DateTime.now().toUtc()),
        shiftId: 'SH1',
        cashierId: 'sara',
      ),
    ]));
    expect(find.text('Uncategorised'), findsWidgets);
    expect(find.text('No reason'), findsOneWidget);
  });

  testWidgets('payouts split by cashier', (t) async {
    await t.pumpWidget(screen([
      out(20, 'Transport', 'Taxi'),
      out(40, 'Food', 'Ice', cashier: 'omar'),
    ]));
    final byCashier = t.widget<Column>(find.byKey(const Key('expenses-by-cashier')));
    expect(byCashier.children.length, 2);
    expect(find.text('omar'), findsOneWidget);
  });
}
