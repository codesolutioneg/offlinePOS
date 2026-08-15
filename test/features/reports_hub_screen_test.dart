import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/shift_store.dart';
import 'package:offline_pos/core/theme/app_colors.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/reports/reports_hub_screen.dart';

import '../db/sqlite_loader.dart';

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

  /// Every existing tile key, title and destination must survive the switch
  /// from flat ListTiles to coloured cards.
  const tiles = <String, String>{
    'rep-summary': 'Sales report',
    'rep-tax': 'Tax report',
    'rep-top': 'Top products',
    'rep-category': 'Category performance',
    'rep-payment': 'Payment analysis',
    'rep-discounts': 'Discounts',
    'rep-cashier': 'Cashier performance',
    'rep-activity': 'Cancelled, voided & refunded',
    'rep-time': 'Sales by hour',
    'rep-comparison': 'Period comparison',
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
      await t.tap(find.byKey(Key(entry.key)));
      await t.pumpAndSettle();
      expect(find.text(entry.value), findsWidgets, reason: 'tile ${entry.key} did not open');
      await t.pageBack();
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
      order('omar', OrderType.delivery),
    ]));

    // All three of today's orders before any filter.
    expect(find.text('3 order(s) in range'), findsOneWidget);

    await t.tap(find.byKey(const Key('report-cashier-filter')));
    await t.pumpAndSettle();
    await t.tap(find.text('sara').last);
    await t.pumpAndSettle();

    expect(find.text('2 order(s) in range'), findsOneWidget);
  });

  testWidgets('the order-type filter narrows the windowed orders', (t) async {
    tallWindow(t);
    await t.pumpWidget(hubWith([
      order('sara', OrderType.dineIn),
      order('sara', OrderType.takeaway),
      order('omar', OrderType.delivery),
    ]));

    await t.tap(find.byKey(const Key('report-type-filter')));
    await t.pumpAndSettle();
    await t.tap(find.text('Delivery').last);
    await t.pumpAndSettle();

    expect(find.text('1 order(s) in range'), findsOneWidget);
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

  testWidgets('the glance card sits at the top of the hub', (t) async {
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

    await t.tap(find.byKey(const Key('rep-expenses')));
    await t.pumpAndSettle();

    expect(find.text('Taxi'), findsOneWidget);
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

    await t.tap(find.byKey(const Key('rep-expenses')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('expenses-empty-state')), findsOneWidget);
  });

  testWidgets('the comparison gets the period before the chosen one', (t) async {
    tallWindow(t);
    await t.pumpWidget(hubWith([sale(100), sale(40, daysAgo: 1)]));

    // The default range is today, so the period before it is yesterday.
    await t.tap(find.byKey(const Key('rep-comparison')));
    await t.pumpAndSettle();

    expect(find.text('Today  vs  Previous period'), findsOneWidget);
    expect(find.text('100.00'), findsWidgets);
    expect(find.text('40.00'), findsWidgets);
    expect(find.text('+150%'), findsWidgets);
  });
}
