import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/db/database.dart';
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

  /// The hub's 9 report cards plus the range picker do not fit an 800x600
  /// default test surface; a tall window renders them all without needing a
  /// scroll before every tap.
  void tallWindow(WidgetTester t) {
    t.view.physicalSize = const Size(800, 2200);
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
}
