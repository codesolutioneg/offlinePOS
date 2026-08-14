import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/shift_store.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/shift/shift_screen.dart';

import '../db/sqlite_loader.dart';

void main() {
  late Db db;
  late ShiftStore shifts;
  late OrderStore orders;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    shifts = ShiftStore(db);
    orders = OrderStore(db);
  });
  tearDown(() => db.close());

  void sale(double amount, List<OrderPayment> payments) => orders.save(
        Order(
          deviceId: 'till-1',
          cashierId: 'sara',
          lines: [OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: amount)],
          payments: payments,
        )..state = OrderState.paid,
      );

  Widget app({Future<void> Function(String, List<(String, String)>)? onPrintReport}) =>
      MaterialApp(
        home: ShiftScreen(
          store: shifts,
          cashierId: 'sara',
          cashMethodIds: const {1},
          formatAmount: (v) => v.toStringAsFixed(2),
          onPrintReport: onPrintReport,
        ),
      );

  testWidgets('the X read breaks the takings down by tender', (t) async {
    shifts.openShift(openingFloat: 100, cashierId: 'sara');
    sale(40, const [OrderPayment(methodId: 1, amount: 40, label: 'Cash')]);
    sale(30, const [OrderPayment(methodId: 2, amount: 30, label: 'Visa')]);

    await t.pumpWidget(app());

    expect(find.text('Payment mix'), findsOneWidget);
    expect(find.text('Cash'), findsOneWidget);
    expect(find.text('Visa'), findsOneWidget);
    expect(find.text('30.00'), findsOneWidget);
    // The drawer figures are untouched by the breakdown: 100 float + 40 cash.
    expect(find.text('140.00'), findsOneWidget);
  });

  testWidgets('a shift with no sales shows no tender section', (t) async {
    shifts.openShift(openingFloat: 100, cashierId: 'sara');

    await t.pumpWidget(app());

    expect(find.text('Payment mix'), findsNothing);
  });

  testWidgets('the printed X report carries the tender rows under the sales line',
      (t) async {
    shifts.openShift(openingFloat: 0, cashierId: 'sara');
    sale(40, const [OrderPayment(methodId: 1, amount: 40, label: 'Cash')]);
    sale(30, const [OrderPayment(methodId: 2, amount: 30, label: 'Visa')]);
    String? title;
    var rows = <(String, String)>[];
    await t.pumpWidget(app(onPrintReport: (reportTitle, reportRows) async {
      title = reportTitle;
      rows = reportRows;
    }));

    await t.tap(find.byKey(const Key('print-x')));
    await t.pumpAndSettle();

    expect(title, 'X Report');
    // Indented, and directly under the figure they break down, so the paper reads
    // as one block rather than two lists to cross-reference.
    expect(rows.take(3), [
      ('Sales (2)', '70.00'),
      ('  Cash', '40.00'),
      ('  Visa', '30.00'),
    ]);
  });
}
