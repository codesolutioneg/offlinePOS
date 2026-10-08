import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/shift_store.dart';
import 'package:offline_pos/core/i18n/l10n.dart';
import 'package:offline_pos/domain/attendance_entry.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/domain/delivery.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/domain/report_sources.dart';
import 'package:offline_pos/features/reports/reports_hub_screen.dart';
import 'package:offline_pos/features/reports/restaurant_analytics.dart';
import 'package:offline_pos/features/reports/rm/rm_bindings.dart';
import 'package:offline_pos/features/reports/rm/rm_layout.dart';
import 'package:offline_pos/features/reports/rm/rm_pdf.dart';
import 'package:offline_pos/features/reports/rm/rm_report_viewer.dart';

import '../db/sqlite_loader.dart';
import '../ui/report_period.dart';

/// A restaurant's three days of trading, run through every report the hub
/// offers, in English and in Arabic: each report has to open over it, show its
/// figures, and turn into a PDF, and the reports have to agree on the money.
void main() {
  late Db db;
  late AuditLog audit;
  late ShiftStore shifts;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    audit = AuditLog(db);
    shifts = ShiftStore(db);
  });
  tearDown(() => db.close());

  const categories = [
    Category(id: 100, name: 'Food'),
    Category(id: 1, name: 'Mains', parentId: 100),
    Category(id: 3, name: 'Desserts', parentId: 100),
    Category(id: 200, name: 'Beverages'),
    Category(id: 2, name: 'Drinks', parentId: 200),
  ];
  const costs = {1: 15.0, 2: 50.0, 3: 3.0, 4: 10.0, 5: 12.0, 6: 9.0};
  const staffNames = {'sara': 'Sara', 'omar': 'Omar', 'mona': 'Mona'};
  const drivers = [Driver(id: 'd1', name: 'Hassan', phone: '0100')];

  OrderLine koshary(double qty, {double discount = 0}) => OrderLine(
      productId: 1,
      name: 'Koshary',
      quantity: qty,
      unitPrice: 45,
      categoryId: 1,
      taxRate: 14,
      discountPercent: discount,
      modifiers: [
        OrderModifier(
            modifierId: 1,
            name: 'Extra sauce',
            quantity: 1,
            unitPrice: 5,
            productId: 7),
      ]);
  OrderLine chicken(double qty) => OrderLine(
      productId: 2,
      name: 'Grilled chicken',
      quantity: qty,
      unitPrice: 120,
      categoryId: 1,
      taxRate: 14);
  OrderLine tea(double qty) => OrderLine(
      productId: 3,
      name: 'Tea',
      quantity: qty,
      unitPrice: 15,
      categoryId: 2,
      taxRate: 14);
  OrderLine juice(double qty) => OrderLine(
      productId: 4,
      name: 'Mango juice',
      quantity: qty,
      unitPrice: 35,
      categoryId: 2,
      taxRate: 14);
  OrderLine omAli(double qty) => OrderLine(
      productId: 5,
      name: 'Om Ali',
      quantity: qty,
      unitPrice: 40,
      categoryId: 3,
      taxRate: 14);
  OrderLine pudding(double qty) => OrderLine(
      productId: 6,
      name: 'Rice pudding',
      quantity: qty,
      unitPrice: 30,
      categoryId: 3,
      taxRate: 14);

  const cash = 'Cash';
  const card = 'Card';

  /// Three days of sales: today, yesterday and the day before, across every
  /// kind of order, tender, discount, refund and delivery the till rings.
  List<Order> demoOrders() {
    final now = DateTime.now();
    DateTime at(int daysAgo, int hour, [int minute = 0]) =>
        DateTime(now.year, now.month, now.day - daysAgo, hour, minute).toUtc();
    final out = <Order>[];
    Order add(Order o, {List<(String, double)>? pay, double? tip}) {
      o.state = OrderState.paid;
      if (tip != null) o.tip = tip;
      if (pay != null) {
        o.payments = [
          for (final (label, amount) in pay)
            OrderPayment(
                methodId: label == cash
                    ? 1
                    : label == card
                        ? -2
                        : -3,
                amount: amount,
                label: label),
        ];
      }
      out.add(o);
      return o;
    }

    for (var day = 0; day < 3; day++) {
      final cashier = ['sara', 'omar', 'mona'][day];
      // Dine-in with service, covers, a table and a split tender.
      final dine = Order(
        deviceId: 'till-1',
        cashierId: cashier,
        type: OrderType.dineIn,
        tableLabel: 'T${day + 1}',
        guestCount: 4,
        serviceChargePercent: 12,
        createdAt: at(day, 13, 10),
        lines: [koshary(2), chicken(1), tea(4), omAli(2)],
      );
      add(dine, pay: [(cash, 200), (card, dine.total - 200)]);

      // Takeaway paid by card with a tip.
      final take = Order(
        deviceId: 'till-1',
        cashierId: cashier,
        type: OrderType.takeaway,
        guestCount: 1,
        createdAt: at(day, 15, 30),
        lines: [juice(2), pudding(1)],
      );
      add(take, pay: [(card, take.total + 10)], tip: 10);

      // The shop's own delivery, with a driver and a delivery charge, cash.
      final delivery = Order(
        deviceId: 'till-1',
        cashierId: cashier,
        type: OrderType.storeDelivery,
        guestCount: 2,
        deliveryCost: 20,
        customerName: 'Ahmed Ali',
        customerPhone: '01001234567',
        customerAddress: 'Nasr City',
        driverId: 'd1',
        driverName: 'Hassan',
        createdAt: at(day, 19, 45),
        lines: [chicken(2), juice(2)],
      );
      add(delivery, pay: [(cash, delivery.total)]);

      // An aggregator's delivery with a 10% check discount, untendered (cash).
      add(Order(
        deviceId: 'till-1',
        cashierId: cashier,
        type: OrderType.deliveryFromCompany,
        deliveryChannel: 'Talabat',
        companyOrderNo: 'TB-${1000 + day}',
        discountPercent: 10,
        discountReason: 'Promo',
        guestCount: 1,
        createdAt: at(day, 21, 5),
        lines: [koshary(3), tea(2)],
      ));
    }

    // Today also has a car order with a comped line, a to-go order signed for
    // on account, and a refund of yesterday's takeaway pudding.
    add(Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      type: OrderType.carDelivery,
      guestCount: 2,
      createdAt: at(0, 17, 20),
      lines: [koshary(1, discount: 100), juice(1)],
    ));
    final account = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      type: OrderType.toGo,
      partnerId: 42,
      customerName: 'Nile Company',
      customerPhone: '0222222222',
      guestCount: 3,
      createdAt: at(0, 12, 40),
      lines: [chicken(3), tea(3)],
    );
    add(account, pay: [(kOnAccountLabel, account.total)]);
    final refunded = out.firstWhere((o) => o.type == OrderType.takeaway);
    final refund = Order(
      deviceId: 'till-1',
      cashierId: 'omar',
      type: OrderType.takeaway,
      refundOfUuid: refunded.uuid,
      createdAt: at(1, 18, 0),
      lines: [pudding(-1)],
    );
    add(refund, pay: [(cash, refund.total)]);
    return out;
  }

  final attendance = MemoryReportAttendance([
    for (var day = 0; day < 3; day++)
      for (final (i, who) in ['sara', 'omar', 'mona'].indexed)
        AttendanceEntry(
          id: day * 10 + i,
          staffId: who,
          clockIn: DateTime.now()
              .subtract(Duration(days: day, hours: 9 - i))
              .toUtc(),
          clockOut: day == 0 && i == 0
              ? null
              : DateTime.now()
                  .subtract(Duration(days: day, hours: 1 + i))
                  .toUtc(),
        ),
  ]);

  void seedDrawerAndAudit(List<Order> orders) {
    shifts.openShift(openingFloat: 500, cashierId: 'sara');
    shifts.addMovement('out', 75, reason: 'Gas cylinder', category: 'Kitchen');
    shifts.addMovement('out', 40, reason: 'Taxi', category: 'Transport');
    shifts.addMovement('in', 200, reason: 'Change from bank');
    final dine = orders.first;
    audit.record('sara', 'line.voided',
        detail: '${dine.uuid}|Tea|Customer changed mind');
    audit.record('omar', 'order.cancelled', detail: orders[1].uuid);
  }

  Widget hub(List<Order> orders, Locale locale) => MaterialApp(
        locale: locale,
        supportedLocales: kSupportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: ReportsHubScreen(
          allOrders: orders,
          categories: categories,
          costs: costs,
          formatAmount: (v) => v.toStringAsFixed(2),
          audit: audit,
          shifts: shifts,
          attendance: attendance,
          staffNames: staffNames,
          drivers: drivers,
          shopName: 'Demo shop',
          ranBy: 'Sara',
        ),
      );

  void bigWindow(WidgetTester t) {
    t.view.physicalSize = const Size(1600, 3200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

  /// Every piece of text on the report page that is open.
  List<String> pageTexts(WidgetTester t) => [
        for (final w in t.widgetList<Text>(find.descendant(
            of: find.byKey(const Key('rm-page')), matching: find.byType(Text))))
          w.data ?? '',
      ];

  /// Every piece of text anywhere on screen, offstage included.
  List<String> screenTexts(WidgetTester t) => [
        for (final w in t.widgetList<Text>(
            find.byType(Text, skipOffstage: false)))
          w.data ?? w.textSpan?.toPlainText() ?? '',
      ];

  /// Closes the report or screen on top, in either language: the tester's own
  /// page back looks for an English tooltip.
  Future<void> close(WidgetTester t) async {
    final page = find.byKey(const Key('rm-close'));
    await t.tap(page.evaluate().isNotEmpty ? page : find.byType(BackButton).last);
    await t.pumpAndSettle();
  }

  /// Nothing went wrong drawing [what]; when something did, says what it was.
  void expectNoError(WidgetTester t, String what) {
    final e = t.takeException();
    if (e == null) return;
    fail('$what: ${e is FlutterError ? e.toStringDeep() : e}');
  }

  final figure = RegExp(r'^-?[\d,]+\.\d\d$');

  /// The page holds at least [min] figures that are not zero, past the page
  /// number its heading carries.
  void expectFigures(WidgetTester t, String key, {int min = 2}) {
    final number = RegExp(r'^-?[\d,]+(\.\d+)?%?$');
    final money = pageTexts(t)
        .map((s) => s.trim())
        .where((s) =>
            number.hasMatch(s) &&
            double.parse(s.replaceAll(RegExp('[,%]'), '')) != 0)
        .toList();
    expect(money.length, greaterThanOrEqualTo(min),
        reason: '$key shows ${money.length} figures: ${pageTexts(t)}');
  }

  Future<void> expectPdf(WidgetTester t, String key) async {
    final viewer = t.widget<RmReportViewer>(find.byType(RmReportViewer));
    final bytes = await t.runAsync(() => buildRmPdf(viewer.document));
    expect(bytes, isNotNull, reason: '$key built no PDF');
    expect(bytes!.length, greaterThan(1000), reason: '$key PDF is empty');
  }

  /// The till's own reports and what each must show over the demo data.
  const tillReports = [
    'rep-session-summary',
    'rep-session-detail',
    'rep-item-sales',
    'rep-detailed-discounts',
    'rep-time',
    'rep-expenses',
    'rep-refunds',
    'rep-activity',
    'rep-driver',
    'rep-payment',
    'rep-summary',
    'rep-tax',
    'rep-group-sales',
    'rep-revenue-center',
    'rep-daily-sales',
    'rep-top',
    'rep-category',
    'rep-discounts',
    'rep-refunds-summary',
    'rep-modifiers',
    'rep-period-compare',
    'rep-hours',
    'rep-cashier',
    'rep-cost-sales',
    'rep-menu-eng',
    'rep-receivables',
  ];

  for (final locale in const [Locale('en'), Locale('ar')]) {
    testWidgets(
        'every till report opens over the demo data and exports '
        '(${locale.languageCode})', (t) async {
      bigWindow(t);
      final orders = demoOrders();
      seedDrawerAndAudit(orders);
      await t.pumpWidget(hub(orders, locale));
      await t.pumpAndSettle();

      final noOrders = locale.languageCode == 'ar' ? 'لا توجد طلبات' : 'No orders';
      for (final key in tillReports) {
        expect(find.byKey(Key(key)), findsOneWidget, reason: 'no tile $key');
        await tapReport(t, key);
        expectNoError(t, '$key threw');
        expect(find.text(noOrders, skipOffstage: false), findsNothing,
            reason: '$key found no orders');
        if (find.byKey(const Key('rm-page')).evaluate().isNotEmpty) {
          expectFigures(t, key);
          await expectPdf(t, key);
        } else {
          // A report without a table opens as its own screen.
          expect(screenTexts(t).where((s) => figure.hasMatch(s.trim())),
              isNotEmpty,
              reason: '$key shows no figures: ${screenTexts(t)}');
        }
        await close(t);
        expectNoError(t, '$key threw on close');
      }
    });

    testWidgets(
        'every back-office layout opens, the connected ones over the data '
        '(${locale.languageCode})', (t) async {
      bigWindow(t);
      final orders = demoOrders();
      await t.pumpWidget(hub(orders, locale));
      await t.pumpAndSettle();

      final layouts = parseRmReports(
          File('assets/report_layouts/layouts.json').readAsStringSync());
      expect(layouts, isNotEmpty);
      for (final group in {for (final r in layouts) r.group}) {
        final folder = find.byKey(Key('rm-group-$group'));
        await t.scrollUntilVisible(folder, 300,
            scrollable: find.byType(Scrollable).first);
        await t.tap(folder);
        await t.pumpAndSettle();
      }

      final connected = <String>[];
      for (final r in layouts) {
        await tapReport(t, 'rm-${r.id}');
        expectNoError(t, 'rm-${r.id} threw');
        expect(find.byType(RmReportViewer), findsOneWidget,
            reason: 'rm-${r.id} did not open');
        final wired = bindRmReport(r.id,
                orders: orders, categories: categories, costs: costs) !=
            null;
        // A layout with nothing to fill in has nothing to warn about.
        if (wired) {
          expect(find.byKey(const Key('rm-unwired')), findsNothing,
              reason: 'rm-${r.id} is connected but says it is not');
          connected.add(r.id);
          expectFigures(t, 'rm-${r.id}');
          await expectPdf(t, 'rm-${r.id}');
        }
        await close(t);
        expectNoError(t, 'rm-${r.id} threw on close');
      }
      debugPrint('layouts: ${layouts.length}, connected: ${connected.length} '
          '(${connected.join(', ')})');
    });

    testWidgets('every Flash report opens over the demo data '
        '(${locale.languageCode})', (t) async {
      bigWindow(t);
      await t.pumpWidget(hub(demoOrders(), locale));
      await t.pumpAndSettle();

      for (final kind in const [
        'collector',
        'summary',
        'delivery',
        'today',
        'paymentMethod',
      ]) {
        await t.tap(find.byKey(const Key('rep-flash')));
        await t.pumpAndSettle();
        expectNoError(t, 'picking flash');
        await t.tap(find.byKey(const Key('report-run')));
        await t.pumpAndSettle();
        expectNoError(t, 'flash type dialog');
        await t.tap(find.byKey(Key('flash-kind-$kind')));
        await t.pumpAndSettle();
        expectNoError(t, 'flash $kind period dialog');
        await t.tap(find.byKey(const Key('period-all')).last);
        await t.pumpAndSettle();
        if (kind == 'today') {
          await t.tap(find.byKey(const Key('flash-today-all')));
          await t.pumpAndSettle();
        } else if (kind == 'paymentMethod') {
          await t.tap(find.text(card).last);
          await t.pumpAndSettle();
        }
        expectNoError(t, 'flash $kind threw');
        expect(find.byKey(const Key('flash-preview-screen')), findsOneWidget,
            reason: 'flash $kind did not open');
        expect(screenTexts(t).where((s) => RegExp(r'[1-9]').hasMatch(s)),
            isNotEmpty);
        await close(t);
      }
    });
  }

  testWidgets('the reports agree on the demo data\'s money', (t) async {
    bigWindow(t);
    final orders = demoOrders();
    seedDrawerAndAudit(orders);
    final totals = reportTotals(orders, costs);
    String money(double v) => v.toStringAsFixed(2);
    await t.pumpWidget(hub(orders, const Locale('en')));
    await t.pumpAndSettle();

    final pay = paymentTypes(orders);
    final tips = orders.fold(0.0, (s, o) => s + o.tip);
    final delivery = orders.fold(0.0, (s, o) => s + o.deliveryCost);

    // The demo data's own sums, worked out without any report.
    expect(money(totals.net), '3260.00');
    expect(money(totals.total), '3900.09');
    expect(money(pay.values.fold(0.0, (s, v) => s + v)), money(totals.total));

    Future<void> expectShows(String key, List<double> figures) async {
      await tapReport(t, key);
      final texts = pageTexts(t);
      for (final f in figures) {
        expect(texts, contains(money(f)),
            reason: '$key does not show ${money(f)}: $texts');
      }
      await close(t);
    }

    await expectShows('rep-session-detail',
        [totals.net, totals.checkDiscount, totals.taxes, totals.total]);
    await expectShows('rep-revenue-center',
        [totals.net, totals.taxes, totals.total]);
    await expectShows('rep-daily-sales', [totals.net, totals.total]);
    await expectShows('rep-group-sales', [totals.net]);
    await expectShows('rep-item-sales', [totals.net]);
    await expectShows('rep-payment', [pay['Cash']!, pay['Card']!, pay[kOnAccountLabel]!]);
    // The summary's payment mix counts an untendered sale as cash, like the
    // payment report, and its discounts are every discount given.
    await expectShows('rep-summary', [
      totals.total,
      totals.discount,
      tips,
      delivery,
      pay['Cash']!,
      pay['Card']!,
    ]);
    await expectShows('rep-discounts', [totals.checkDiscount, totals.discount]);
    await expectShows('rep-detailed-discounts',
        [totals.checkDiscount, totals.lineDiscount, totals.discount]);
    // The tax the till charged, and what the customers paid less tips and
    // delivery, which carry no tax.
    await expectShows(
        'rep-tax', [totals.vat, totals.total - tips - delivery]);
    await expectShows('rep-refunds-summary', [-30]);
    await expectShows('rep-receivables', [pay[kOnAccountLabel]!]);

    // Each cashier's takings add up to the shop's.
    await tapReport(t, 'rep-cashier');
    final byCashier = [
      for (final who in staffNames.keys)
        double.parse(pageLine(t, who)[1]),
    ];
    expect(money(byCashier.fold(0.0, (s, v) => s + v)), money(totals.total));
    await close(t);

    // The session summary balances: its debits equal its credits.
    await tapReport(t, 'rep-session-summary');
    final balance = pageLine(t, 'Report Totals:');
    expect(balance.length, 2);
    expect(balance.first, balance.last);
    await close(t);

    // A count reads as a count.
    await tapReport(t, 'rep-period-compare');
    expect(pageLine(t, 'Orders').first, '${orders.length}');
    await close(t);
  });
}
