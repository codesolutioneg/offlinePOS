import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/shift_store.dart';
import 'package:offline_pos/core/theme/app_colors.dart';
import 'package:offline_pos/core/theme/app_theme.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/reports/reports_hub_screen.dart';
import 'package:offline_pos/features/reports/rm/rm_report_viewer.dart';

import '../db/sqlite_loader.dart';
import '../ui/report_period.dart';

void main() {
  late Db db;
  late AuditLog audit;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    audit = AuditLog(db);
  });
  tearDown(() => db.close());

  /// The hub's report cards plus the glance card and the range picker do not fit
  /// an 800x600 default test surface; a tall window renders them all without
  /// needing a scroll before every tap.
  void tallWindow(WidgetTester t) {
    t.view.physicalSize = const Size(800, 3200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

  Widget app() => MaterialApp(
        home: ReportsHubScreen(
          allOrders: const [],
          categories: const [],
          formatAmount: (v) => v.toStringAsFixed(2),
          audit: audit,
        ),
      );

  /// Pick the report in the tree, set the period on the form, and open it.
  Future<void> openReport(WidgetTester t, String key,
      {String period = 'today'}) async {
    await t.tap(find.byKey(Key(key)));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('report-period')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('period-$period')).last);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('report-run')));
    await t.pumpAndSettle();
  }


  /// Every existing tile key, title and destination must survive the switch
  /// from flat ListTiles to coloured cards.
  const tiles = <String, String>{
    'rep-summary': 'Sales report',
    'rep-tax': 'Tax report',
    'rep-top': 'Top products',
    'rep-category': 'Sales By Category',
    'rep-payment': 'Payment analysis',
    'rep-discounts': 'Discounts',
    'rep-cashier': 'Cashier performance',
    'rep-activity': 'Cancelled, voided & refunded',
    'rep-time': 'Sales by hour',
    'rep-period-compare': 'Period comparison',
    'rep-modifiers': 'Modifiers',
    'rep-refunds': 'Refunds & voids',
  };

  testWidgets('every report tile is present and opens its report', (t) async {
    tallWindow(t);
    await t.pumpWidget(app());

    for (final key in tiles.keys) {
      expect(find.byKey(Key(key)), findsOneWidget, reason: 'missing tile $key');
    }

    for (final entry in tiles.entries) {
      await openReport(t, entry.key);
      expect(find.text(entry.value, skipOffstage: false), findsWidgets,
          reason: 'tile ${entry.key} did not open');
      await closeReport(t);
      await t.pumpAndSettle();
    }
  });

  testWidgets(
      'financial and audit/oversight tiles are tinted from two distinct colour families',
      (t) async {
    tallWindow(t);
    await t.pumpWidget(app());

    Color badgeColorOf(String key) {
      final icon = t.widget<Icon>(find.descendant(
        of: find.byKey(Key(key)),
        matching: find.byType(Icon),
      ).first);
      return icon.color!;
    }

    final financial = ['rep-summary', 'rep-tax', 'rep-top', 'rep-category', 'rep-payment', 'rep-time']
        .map(badgeColorOf)
        .toSet();
    final oversight = ['rep-activity', 'rep-discounts', 'rep-cashier'].map(badgeColorOf).toSet();

    // The two groups must not share a single colour, otherwise they would not
    // "read apart" as required.
    expect(financial.intersection(oversight), isEmpty);
    // The audit/oversight report for cancels/voids/refunds keeps the app's
    // existing danger colour, matching the audit log's own colouring.
    expect(badgeColorOf('rep-activity'), AppColors.error);
  });

  Order order(String cashier, OrderType type) =>
      Order(deviceId: 'd', cashierId: cashier, type: type);

  Widget hubWith(List<Order> orders) => MaterialApp(
        home: ReportsHubScreen(
          allOrders: orders,
          categories: const [],
          formatAmount: (v) => v.toStringAsFixed(2),
          audit: audit,
        ),
      );

  testWidgets('the cashier filter narrows the windowed orders', (t) async {
    tallWindow(t);
    await t.pumpWidget(hubWith([
      order('sara', OrderType.dineIn),
      order('sara', OrderType.takeaway),
      order('omar', OrderType.storeDelivery),
    ]));

    await t.tap(find.byKey(const Key('report-cashier-filter')));
    await t.pumpAndSettle();
    await t.tap(find.text('sara').last);
    await t.pumpAndSettle();

    await openReport(t, 'rep-summary');
    expect(pageLine(t, 'Orders'), contains('2'));
  });

  testWidgets('the order-type filter narrows the windowed orders', (t) async {
    tallWindow(t);
    await t.pumpWidget(hubWith([
      order('sara', OrderType.dineIn),
      order('sara', OrderType.takeaway),
      order('omar', OrderType.storeDelivery),
    ]));

    await t.tap(find.byKey(const Key('report-type-filter')));
    await t.pumpAndSettle();
    await t.tap(find.text('Store delivery').last);
    await t.pumpAndSettle();

    await openReport(t, 'rep-summary');
    expect(pageLine(t, 'Orders'), contains('1'));
  });

  testWidgets('the table filter narrows the windowed orders', (t) async {
    tallWindow(t);
    await t.pumpWidget(hubWith([
      order('sara', OrderType.dineIn)..tableLabel = 'T1',
      order('sara', OrderType.dineIn)..tableLabel = 'T2',
      order('omar', OrderType.takeaway),
    ]));

    await t.enterText(find.byKey(const Key('report-table-filter')), 't1');
    await openReport(t, 'rep-summary');
    expect(pageLine(t, 'Orders'), contains('1'));
  });

  testWidgets('a bundled back-office layout opens in the page viewer',
      (t) async {
    tallWindow(t);
    await t.pumpWidget(app());
    await t.pumpAndSettle();

    // Folded shut until asked for.
    expect(find.byKey(const Key('rm-noSales')), findsNothing);
    await t.tap(find.byKey(const Key('rm-group-Sales Reports')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('rm-noSales')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('report-run')));
    await t.pumpAndSettle();

    expect(find.byType(RmReportViewer), findsOneWidget);
    // Nobody has connected this one to the till's sales yet, and it says so.
    expect(find.byKey(const Key('rm-unwired')), findsOneWidget);
  });

  testWidgets('a till report with a connected layout opens as that layout',
      (t) async {
    tallWindow(t);
    await t.pumpWidget(hubWith([
      Order(deviceId: 'd', cashierId: 'sara', type: OrderType.dineIn, lines: [
        OrderLine(productId: 1, name: 'Pizza', quantity: 2, unitPrice: 100),
      ]),
    ]));
    await t.pumpAndSettle();

    await openReport(t, 'rep-session-summary');

    expect(find.byType(RmReportViewer), findsOneWidget);
    expect(find.byKey(const Key('rm-unwired')), findsNothing);
    // The back office's own sections and columns, over the till's figures.
    expect(find.text('Payment Types'), findsOneWidget);
    expect(pageLine(t, 'Report Totals:'), ['200.00', '200.00']);
  });

  testWidgets('the thermal button prints the report page on the receipt roll',
      (t) async {
    tallWindow(t);
    ThermalReport? printed;
    await t.pumpWidget(MaterialApp(
      home: ReportsHubScreen(
        allOrders: [
          order('sara', OrderType.dineIn),
          order('sara', OrderType.takeaway),
        ],
        categories: const [],
        formatAmount: (v) => v.toStringAsFixed(2),
        audit: audit,
        onPrintReport: (report) async => printed = report,
      ),
    ));

    await openReport(t, 'rep-summary');
    await t.tap(find.byKey(const Key('rm-print')));
    await t.pumpAndSettle();

    expect(printed!.title, 'Sales summary');
    // The session and the filter head it, as they head the page.
    expect(printed!.period, 'Today');
    expect(printed!.filter, 'None');
    expect(
        printed!.rows.any((r) => r.length > 2 && r[1] == 'Orders' && r[2] == '2'),
        isTrue,
        reason: '${printed!.rows}');
  });

  testWidgets('without a printer hook the window has no thermal button',
      (t) async {
    tallWindow(t);
    await t.pumpWidget(app());

    await openReport(t, 'rep-summary');
    expect(find.byKey(const Key('rm-page')), findsOneWidget);
    expect(find.byKey(const Key('rm-print')), findsNothing);
  });

  testWidgets('nothing runs until a report is picked in the tree', (t) async {
    tallWindow(t);
    await t.pumpWidget(app());

    final run = t.widget<InkWell>(find.byKey(const Key('report-run')));
    expect(run.onTap, isNull);
  });

  testWidgets('picking a session sets the period to that shift', (t) async {
    tallWindow(t);
    final shifts = ShiftStore(db);
    final shift = shifts.openShift(openingFloat: 0, cashierId: 'sara');
    shifts.addMovement('out', 25, reason: 'Taxi', category: 'Transport');

    await t.pumpWidget(MaterialApp(
      home: ReportsHubScreen(
        allOrders: const [],
        categories: const [],
        formatAmount: (v) => v.toStringAsFixed(2),
        audit: audit,
        shifts: shifts,
      ),
    ));

    await t.tap(find.byKey(Key('report-session-${shift.id}')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('rep-expenses')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('report-run')));
    await t.pumpAndSettle();

    expect(find.text('Taxi'), findsWidgets);
  });

  Order sale(double amount, {int daysAgo = 0}) {
    final at = DateTime.now().subtract(Duration(days: daysAgo));
    return Order(
      deviceId: 'd',
      cashierId: 'sara',
      type: OrderType.takeaway,
      createdAt: DateTime(at.year, at.month, at.day, 12).toUtc(),
      lines: [
        OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: amount)
      ],
    );
  }

  testWidgets('the glance card sits in the hub', (t) async {
    tallWindow(t);
    await t.pumpWidget(hubWith([sale(100)]));

    expect(find.byKey(const Key('today-glance')), findsOneWidget);
    expect(find.text('Today at a glance'), findsOneWidget);
  });

  testWidgets('without a shift store there is no expenses tile', (t) async {
    tallWindow(t);
    await t.pumpWidget(hubWith(const []));
    expect(find.byKey(const Key('rep-expenses')), findsNothing);
  });

  testWidgets('the expenses report reads the paid-outs out of the shifts',
      (t) async {
    tallWindow(t);
    final shifts = ShiftStore(db);
    shifts.openShift(openingFloat: 0, cashierId: 'sara');
    shifts.addMovement('out', 25, reason: 'Taxi', category: 'Transport');

    await t.pumpWidget(MaterialApp(
      home: ReportsHubScreen(
        allOrders: const [],
        categories: const [],
        formatAmount: (v) => v.toStringAsFixed(2),
        audit: audit,
        shifts: shifts,
      ),
    ));

    await openReport(t, 'rep-expenses');

    expect(find.text('Taxi'), findsWidgets);
    expect(find.text('25.00'), findsWidgets);
  });

  testWidgets('a range with no paid-outs opens an empty expenses report',
      (t) async {
    tallWindow(t);
    await t.pumpWidget(MaterialApp(
      home: ReportsHubScreen(
        allOrders: const [],
        categories: const [],
        formatAmount: (v) => v.toStringAsFixed(2),
        audit: audit,
        shifts: ShiftStore(db),
      ),
    ));

    await openReport(t, 'rep-expenses');
    expect(find.byKey(const Key('expenses-empty-state'), skipOffstage: false),
        findsOneWidget);
  });

  testWidgets('the comparison gets the period before the chosen one', (t) async {
    tallWindow(t);
    await t.pumpWidget(hubWith([sale(100), sale(40, daysAgo: 1)]));

    // Today was picked, so the period before it is yesterday.
    await openReport(t, 'rep-period-compare');

    expect(find.text('Today  vs  Previous period', skipOffstage: false),
        findsOneWidget);
    expect(find.text('100.00'), findsWidgets);
    expect(find.text('40.00'), findsWidgets);
    expect(find.text('+150%', skipOffstage: false), findsWidgets);
  });

  testWidgets('the title bar reads on the light face in the dark theme',
      (t) async {
    await t.pumpWidget(MaterialApp(
      theme: AppTheme.dark(),
      home: Navigator(
        onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => const SizedBox()),
      ),
    ));
    final nav = t.state<NavigatorState>(find.byType(Navigator).last);
    nav.push(MaterialPageRoute(
        builder: (_) => ReportsHubScreen(
              allOrders: const [],
              categories: const [],
              formatAmount: (v) => v.toStringAsFixed(2),
              audit: audit,
            )));
    await t.pumpAndSettle();
    final title = t.widget<DefaultTextStyle>(find
        .ancestor(of: find.text('Reports'), matching: find.byType(DefaultTextStyle))
        .first);
    expect(title.style.color, Colors.black);
    final back = IconTheme.of(t.element(find.byType(BackButtonIcon)));
    expect(back.color, Colors.black);
  });
}
