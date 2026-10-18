import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/shift_store.dart';
import 'package:offline_pos/core/i18n/l10n.dart';
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
              {DateTime? until, void Function(String status)? onProgress})
          catchUp, {
      List<String>? blocked,
      List<String>? overrides,
      Future<DateTime?> Function(DateTime since,
              {void Function(DateTime readyAt)? onWait, Future<void>? cancelled})?
          settle,
    }) =>
        MaterialApp(
          home: ShiftScreen(
            store: shifts,
            cashierId: 'sara',
            formatAmount: (v) => v.toStringAsFixed(2),
            startCloseOnOpen: true,
            catchUpOtherTills: catchUp,
            settleCloseCutoff: settle,
            onCloseBlocked: (r) => blocked?.add(r),
            onCloseOverride: (r, d) => overrides?.add('$r: $d'),
          ),
        );

    testWidgets('with every till in, the count is asked for straight away',
        (t) async {
      final opened = shifts.openShift(openingFloat: 0, cashierId: 'sara');
      DateTime? since;
      var bounded = false;
      await t.pumpWidget(closing((s, {until, onProgress}) async {
        since = s;
        bounded = until != null;
        return const [];
      }));
      await t.pumpAndSettle();

      expect(since, opened.openedAt);
      expect(bounded, isFalse, reason: 'before the count the tills are read up to now');
      expect(find.byKey(const Key('tills-unreachable')), findsNothing);
      expect(find.text('Counted cash'), findsOneWidget);
    });

    testWidgets('the progress a till reports reads in the cashier\'s language',
        (t) async {
      shifts.openShift(openingFloat: 0, cashierId: 'sara');
      final answer = Completer<List<String>>();
      await t.pumpWidget(MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: kSupportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: ShiftScreen(
          store: shifts,
          cashierId: 'sara',
          formatAmount: (v) => v.toStringAsFixed(2),
          startCloseOnOpen: true,
          catchUpOtherTills: (s, {until, onProgress}) {
            onProgress?.call('Checking every till handed over its sales...');
            return answer.future;
          },
        ),
      ));
      await t.pump();
      await t.pump();

      expect(find.text('Checking every till handed over its sales...'), findsNothing);
      expect(find.text('جاري التأكد من أن كل الأجهزة سلّمت مبيعاتها...'),
          findsOneWidget);
      answer.complete(const []);
      await t.pumpAndSettle();
    });

    testWidgets('a silent till stops the close, and is asked again', (t) async {
      shifts.openShift(openingFloat: 0, cashierId: 'sara');
      final blocked = <String>[];
      var calls = 0;
      await t.pumpWidget(closing((s, {until, onProgress}) async {
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
          closing((s, {until, onProgress}) async => ['Bar: unreachable']));
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
      await t.pumpWidget(closing((s, {until, onProgress}) async => ['Bar: unreachable'],
          overrides: overrides));
      await t.pumpAndSettle();

      await t.tap(find.byKey(const Key('tills-unreachable-close-anyway')));
      await t.pumpAndSettle();

      expect(overrides,
          ['shift.close.override.tills_unreachable: Bar: unreachable']);
      expect(find.text('Counted cash'), findsOneWidget);
    });

    Future<void> countAndConfirm(WidgetTester t, String digits) async {
      for (final d in digits.split('')) {
        await t.tap(find.byKey(Key('key-$d')));
        await t.pump();
      }
      await t.tap(find.byKey(const Key('keypad-ok')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('confirm-close-shift')));
      await t.pumpAndSettle();
    }

    testWidgets('the tills are asked again just before the session closes',
        (t) async {
      shifts.openShift(openingFloat: 0, cashierId: 'sara');
      final bounds = <DateTime?>[];
      await t.pumpWidget(closing((s, {until, onProgress}) async {
        bounds.add(until);
        return const [];
      }));
      await t.pumpAndSettle();
      expect(bounds, [null]);

      final before = DateTime.now().toUtc();
      await countAndConfirm(t, '0');

      expect(bounds, hasLength(2));
      expect(shifts.currentOpenShift(), isNull);
      expect(find.byKey(const Key('session-done')), findsOneWidget);
      // The shift closes at the instant the tills were compared up to, so the
      // close covers exactly the sales they answered for.
      final closedAt = shifts.recentClosed(limit: 1).single.closedAt;
      expect(closedAt, bounds.last);
      expect(closedAt!.isBefore(before), isFalse);
    });

    testWidgets('the last check and the close land on the bound the clocks '
        'settle on', (t) async {
      final shift = shifts.openShift(openingFloat: 0, cashierId: 'sara');
      final settled = DateTime.now().toUtc().add(const Duration(seconds: 4));
      final bounds = <DateTime?>[];
      final settledFor = <DateTime>[];
      await t.pumpWidget(closing((s, {until, onProgress}) async {
        bounds.add(until);
        return const [];
      }, settle: (since, {onWait, cancelled}) async {
        settledFor.add(since);
        return settled;
      }));
      await t.pumpAndSettle();
      expect(settledFor, isEmpty,
          reason: 'the check before the count is not bounded');

      await countAndConfirm(t, '0');

      expect(settledFor, [shift.openedAt]);
      expect(bounds.last, settled);
      expect(shifts.recentClosed(limit: 1).single.closedAt, settled);
    });

    Future<void> countAndConfirmWhileWaiting(WidgetTester t) async {
      await t.tap(find.byKey(const Key('key-0')));
      await t.pump();
      await t.tap(find.byKey(const Key('keypad-ok')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('confirm-close-shift')));
      await t.pump();
      await t.pump();
    }

    Future<DateTime?> waitUntilCancelled(DateTime since,
        {void Function(DateTime readyAt)? onWait, Future<void>? cancelled}) async {
      onWait?.call(DateTime.now().toUtc().add(const Duration(seconds: 30)));
      await cancelled;
      return null;
    }

    testWidgets('the wait for the clocks counts down and can be cancelled, '
        'leaving the session open', (t) async {
      shifts.openShift(openingFloat: 0, cashierId: 'sara');
      final bounds = <DateTime?>[];
      await t.pumpWidget(closing((s, {until, onProgress}) async {
        bounds.add(until);
        return const [];
      }, settle: waitUntilCancelled));
      await t.pumpAndSettle();

      await countAndConfirmWhileWaiting(t);
      expect(find.textContaining('(30s left)'), findsOneWidget);
      await t.pump(const Duration(seconds: 2));
      expect(find.textContaining('s left)'), findsOneWidget,
          reason: 'the seconds left keep showing while it waits');

      await t.tap(find.byKey(const Key('close-progress-cancel')));
      await t.pumpAndSettle();

      expect(find.byKey(const Key('close-progress')), findsNothing);
      expect(bounds, [null], reason: 'a cancelled close asks no bounded check');
      expect(shifts.currentOpenShift(), isNotNull);
    });

    testWidgets('the wait for the clocks reads in the cashier\'s language',
        (t) async {
      shifts.openShift(openingFloat: 0, cashierId: 'sara');
      await t.pumpWidget(MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: kSupportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: ShiftScreen(
          store: shifts,
          cashierId: 'sara',
          formatAmount: (v) => v.toStringAsFixed(2),
          startCloseOnOpen: true,
          catchUpOtherTills: (s, {until, onProgress}) async => const [],
          settleCloseCutoff: waitUntilCancelled,
        ),
      ));
      await t.pumpAndSettle();

      await countAndConfirmWhileWaiting(t);
      expect(find.textContaining('s left'), findsNothing);
      expect(find.text('انتظار أن تتجاوز ساعة كل جهاز وقت الإغلاق (باقي 30 ثانية)...'),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(const Key('close-progress-cancel')),
              matching: find.text('إلغاء')),
          findsOneWidget);

      await t.tap(find.byKey(const Key('close-progress-cancel')));
      await t.pumpAndSettle();
    });

    testWidgets('a sale rung on another till during the count holds the close',
        (t) async {
      shifts.openShift(openingFloat: 0, cashierId: 'sara');
      final blocked = <String>[];
      var calls = 0;
      await t.pumpWidget(closing((s, {until, onProgress}) async {
        calls++;
        return calls == 2
            ? ['Bar: 1 sale held there is not on this till yet']
            : const [];
      }, blocked: blocked));
      await t.pumpAndSettle();

      await countAndConfirm(t, '0');

      expect(find.byKey(const Key('tills-unreachable')), findsOneWidget);
      expect(find.text('• Bar: 1 sale held there is not on this till yet'),
          findsOneWidget);
      expect(blocked, ['shift.close.blocked.tills_unreachable']);
      expect(shifts.currentOpenShift(), isNotNull);

      await t.tap(find.byKey(const Key('tills-unreachable-cancel')));
      await t.pumpAndSettle();
      expect(shifts.currentOpenShift(), isNotNull);
      expect(find.byKey(const Key('session-done')), findsNothing);
    });

    testWidgets('a retry at the last check moves the close to that attempt',
        (t) async {
      shifts.openShift(openingFloat: 0, cashierId: 'sara');
      final bounds = <DateTime?>[];
      await t.pumpWidget(closing((s, {until, onProgress}) async {
        bounds.add(until);
        return bounds.length == 2 ? ['Bar: unreachable'] : const [];
      }));
      await t.pumpAndSettle();

      await countAndConfirm(t, '0');
      expect(find.byKey(const Key('tills-unreachable')), findsOneWidget);
      await t.tap(find.byKey(const Key('tills-unreachable-retry')));
      await t.pumpAndSettle();

      expect(bounds, hasLength(3));
      expect(bounds[2]!.isBefore(bounds[1]!), isFalse);
      expect(shifts.recentClosed(limit: 1).single.closedAt, bounds[2]);
    });

    testWidgets('a retry at the last check settles the clocks again and closes '
        'at the new bound', (t) async {
      shifts.openShift(openingFloat: 0, cashierId: 'sara');
      final now = DateTime.now().toUtc();
      final settled = [
        now.add(const Duration(seconds: 3)),
        now.add(const Duration(seconds: 9)),
      ];
      var settles = 0;
      final bounds = <DateTime?>[];
      await t.pumpWidget(closing((s, {until, onProgress}) async {
        bounds.add(until);
        return bounds.length == 2 ? ['Bar: unreachable'] : const [];
      }, settle: (since, {onWait, cancelled}) async => settled[settles++]));
      await t.pumpAndSettle();

      await countAndConfirm(t, '0');
      await t.tap(find.byKey(const Key('tills-unreachable-retry')));
      await t.pumpAndSettle();

      expect(settles, 2);
      expect(bounds.sublist(1), settled);
      expect(shifts.recentClosed(limit: 1).single.closedAt, settled[1]);
    });
  });
}
