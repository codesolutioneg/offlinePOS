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

  testWidgets('a cash refund shows on the drawer and lowers the expected cash',
      (t) async {
    shifts.openShift(openingFloat: 100, cashierId: 'sara');
    sale(40, const [OrderPayment(methodId: 1, amount: 40, label: 'Cash')]);
    final sold = orders.recent().first;
    orders.save(Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      lines: [OrderLine(productId: 1, name: 'Pizza', quantity: -1, unitPrice: 15)],
      payments: const [OrderPayment(methodId: 1, amount: -15, label: 'Cash')],
    )
      ..refundOfUuid = sold.uuid
      ..state = OrderState.paid);

    await t.pumpWidget(app());

    expect(find.text('Cash refunds'), findsOneWidget);
    expect(find.text('-15.00'), findsOneWidget);
    // 100 float + 40 cash - 15 refunded.
    expect(find.text('125.00'), findsOneWidget);
    expect(find.text('140.00'), findsNothing);
  });

  testWidgets('a shift with no refunds shows no refund row', (t) async {
    shifts.openShift(openingFloat: 100, cashierId: 'sara');
    sale(40, const [OrderPayment(methodId: 1, amount: 40, label: 'Cash')]);

    await t.pumpWidget(app());

    expect(find.text('Cash refunds'), findsNothing);
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

    // Under the session card, below the fold.
    await t.scrollUntilVisible(find.byKey(const Key('print-x')), 200,
        scrollable: find.byType(Scrollable).first);
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

  testWidgets('Money Drop from the floor opens straight into a cash out',
      (t) async {
    shifts.openShift(openingFloat: 100, cashierId: 'sara');
    await t.pumpWidget(MaterialApp(
      home: ShiftScreen(
        store: shifts,
        cashierId: 'sara',
        formatAmount: (v) => v.toStringAsFixed(2),
        startMovement: 'drop',
      ),
    ));
    await t.pumpAndSettle();

    expect(find.text('Money Drop'), findsWidgets);
    await t.enterText(find.byType(TextField).first, '50');
    await t.tap(find.text('OK'));
    await t.pumpAndSettle();

    final m = shifts.currentOpenShift()!.movements.single;
    expect(m.type, 'out');
    expect(m.amount, 50);
    expect(m.reason, 'Money Drop');
  });

  group('collecting the other tills\' sales before the count', () {
    Widget closing(
      Future<List<String>> Function(DateTime since,
              {void Function(String status)? onProgress})
          catchUp, {
      List<String>? blocked,
      List<String>? overrides,
    }) =>
        MaterialApp(
          home: ShiftScreen(
            store: shifts,
            cashierId: 'sara',
            formatAmount: (v) => v.toStringAsFixed(2),
            startCloseOnOpen: true,
            catchUpOtherTills: catchUp,
            onCloseBlocked: (r) => blocked?.add(r),
            onCloseOverride: (r, d) => overrides?.add('$r: $d'),
          ),
        );

    testWidgets('with every till in, the count is asked for straight away',
        (t) async {
      final opened = shifts.openShift(openingFloat: 0, cashierId: 'sara');
      DateTime? since;
      await t.pumpWidget(closing((s, {onProgress}) async {
        since = s;
        return const [];
      }));
      await t.pumpAndSettle();

      expect(since, opened.openedAt);
      expect(find.byKey(const Key('tills-unreachable')), findsNothing);
      expect(find.text('Counted cash'), findsOneWidget);
    });

    testWidgets('a silent till stops the close, and is asked again', (t) async {
      shifts.openShift(openingFloat: 0, cashierId: 'sara');
      final blocked = <String>[];
      var calls = 0;
      await t.pumpWidget(closing((s, {onProgress}) async {
        calls++;
        return calls == 1 ? ['Bar: unreachable'] : const [];
      }, blocked: blocked));
      await t.pumpAndSettle();

      expect(find.byKey(const Key('tills-unreachable')), findsOneWidget);
      expect(find.text('• Bar: unreachable'), findsOneWidget);
      expect(blocked, ['shift.close.blocked.tills_unreachable']);

      await t.tap(find.byKey(const Key('tills-unreachable-retry')));
      await t.pumpAndSettle();

      expect(calls, 2);
      expect(find.text('Counted cash'), findsOneWidget);
    });

    testWidgets('cancel leaves the shift open', (t) async {
      shifts.openShift(openingFloat: 0, cashierId: 'sara');
      await t.pumpWidget(
          closing((s, {onProgress}) async => ['Bar: unreachable']));
      await t.pumpAndSettle();

      await t.tap(find.byKey(const Key('tills-unreachable-cancel')));
      await t.pumpAndSettle();

      expect(find.text('Counted cash'), findsNothing);
      expect(shifts.currentOpenShift(), isNotNull);
    });

    testWidgets('closing anyway goes on to the count, and says what was skipped',
        (t) async {
      shifts.openShift(openingFloat: 0, cashierId: 'sara');
      final overrides = <String>[];
      await t.pumpWidget(closing((s, {onProgress}) async => ['Bar: unreachable'],
          overrides: overrides));
      await t.pumpAndSettle();

      await t.tap(find.byKey(const Key('tills-unreachable-close-anyway')));
      await t.pumpAndSettle();

      expect(overrides,
          ['shift.close.override.tills_unreachable: Bar: unreachable']);
      expect(find.text('Counted cash'), findsOneWidget);
    });
  });
}
