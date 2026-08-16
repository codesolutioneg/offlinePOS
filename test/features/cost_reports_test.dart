import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/reports/cost_sales_report_screen.dart';
import 'package:offline_pos/features/reports/menu_engineering_report_screen.dart';
import 'package:offline_pos/features/reports/product_margins.dart';

/// The margin maths and the two screens that read it.
void main() {
  String money(double v) => v.toStringAsFixed(2);

  Order sale(List<OrderLine> lines, {double discountPercent = 0, String? refundOf}) {
    final o = Order(deviceId: 'till-1', cashierId: 'sara')
      ..discountPercent = discountPercent
      ..refundOfUuid = refundOf;
    o.lines.addAll(lines);
    return o;
  }

  OrderLine item(int id, String name, double qty, double price,
          {double taxRate = 0}) =>
      OrderLine(
          productId: id,
          name: name,
          quantity: qty,
          unitPrice: price,
          taxRate: taxRate);

  group('the aggregation', () {
    test('margin is revenue net of tax and discount, less what it cost', () {
      // 2 x 115 at 15% tax is 200 net; costing 60 each leaves 80.
      final rows = productMargins(
          [sale([item(1, 'Pizza', 2, 115, taxRate: 15)])], {1: 60});
      final pizza = rows.single;
      expect(pizza.revenue, closeTo(200, 0.001));
      expect(pizza.cost, 120);
      expect(pizza.margin, closeTo(80, 0.001));
      expect(pizza.marginPercent, closeTo(40, 0.001));
    });

    test('a whole-order discount comes off the revenue, not off the cost', () {
      final rows = productMargins(
          [sale([item(1, 'Pizza', 1, 100)], discountPercent: 10)], {1: 50});
      expect(rows.single.revenue, closeTo(90, 0.001));
      expect(rows.single.cost, 50, reason: 'a discount does not make food cheaper');
      expect(rows.single.margin, closeTo(40, 0.001));
    });

    test('a refund nets the units and the margin back out', () {
      final rows = productMargins([
        sale([item(1, 'Pizza', 3, 100)]),
        sale([item(1, 'Pizza', -1, 100)], refundOf: 'earlier'),
      ], {
        1: 40
      });
      expect(rows.single.units, 2);
      expect(rows.single.revenue, closeTo(200, 0.001));
      expect(rows.single.cost, 80);
    });

    test('an uncosted product is marked, never counted as free', () {
      final rows = productMargins([
        sale([item(1, 'Pizza', 1, 100), item(2, 'Water', 1, 20)]),
      ], {
        1: 40
      });
      final water = rows.firstWhere((r) => r.productId == 2);
      expect(water.costed, isFalse);
      expect(water.cost, 0);
    });

    test('a dish keeps its identity when it is renamed mid-window', () {
      final rows = productMargins([
        sale([item(1, 'Pizza', 1, 100)]),
        sale([item(1, 'Pizza Margherita', 1, 100)]),
      ], {
        1: 40
      });
      expect(rows, hasLength(1));
      expect(rows.single.units, 2);
    });
  });

  group('cost vs sales', () {
    Widget screen(List<Order> orders, Map<int, double> costs) => MaterialApp(
          home: CostSalesReportScreen(
              orders: orders, costs: costs, formatAmount: money),
        );

    testWidgets('says so plainly when no cost has ever synced', (t) async {
      await t.pumpWidget(screen([sale([item(1, 'Pizza', 1, 100)])], const {}));
      expect(find.byKey(const Key('cost-empty-state')), findsOneWidget);
    });

    testWidgets('totals only the costed dishes and lists the rest apart',
        (t) async {
      await t.pumpWidget(screen([
        sale([item(1, 'Pizza', 1, 100), item(2, 'Water', 1, 20)]),
      ], {
        1: 40
      }));

      expect(find.byKey(const Key('cost-product-1')), findsOneWidget);
      // Water has no cost, so it never lands in the priced list or the totals.
      expect(find.byKey(const Key('cost-product-2')), findsNothing);
      expect(find.byKey(const Key('cost-not-costed')), findsOneWidget);
      // Revenue 100, cost 40, margin 60: the totals ignore the water entirely.
      expect(find.text('60.00'), findsWidgets);
      expect(find.text('60.0%'), findsWidgets);
    });
  });

  group('menu engineering', () {
    Widget screen(List<Order> orders, Map<int, double> costs) => MaterialApp(
          home: MenuEngineeringReportScreen(
              orders: orders, costs: costs, formatAmount: money),
        );

    testWidgets('sorts the menu into the four corners', (t) async {
      await t.binding.setSurfaceSize(const Size(900, 2400));
      addTearDown(() => t.binding.setSurfaceSize(null));
      // Popular and rich, popular and thin, rare and rich, rare and thin.
      await t.pumpWidget(screen([
        sale([
          item(1, 'Star', 20, 100),
          item(2, 'Plowhorse', 20, 100),
          item(3, 'Puzzle', 1, 100),
          item(4, 'Dog', 1, 100),
        ]),
      ], {
        1: 20,
        2: 90,
        3: 20,
        4: 90,
      }));

      Finder inQuadrant(String q, int id) => find.descendant(
          of: find.byKey(Key('menu-$q')), matching: find.byKey(Key('menu-item-$id')));
      expect(inQuadrant('stars', 1), findsOneWidget);
      expect(inQuadrant('plowhorses', 2), findsOneWidget);
      expect(inQuadrant('puzzles', 3), findsOneWidget);
      expect(inQuadrant('dogs', 4), findsOneWidget);
    });

    testWidgets('an uncosted dish is left out rather than called a dog',
        (t) async {
      await t.binding.setSurfaceSize(const Size(900, 2400));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(screen([
        sale([item(1, 'Pizza', 5, 100), item(2, 'Water', 5, 20)]),
      ], {
        1: 40
      }));

      expect(find.byKey(const Key('menu-item-1')), findsOneWidget);
      expect(find.byKey(const Key('menu-item-2')), findsNothing);
    });
  });
}
