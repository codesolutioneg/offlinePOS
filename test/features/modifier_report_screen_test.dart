import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/reports/modifier_report_screen.dart';

void main() {
  Order sale(List<OrderLine> lines) => Order(
        deviceId: 'd',
        cashierId: 'sara',
        type: OrderType.takeaway,
      )..lines.addAll(lines);

  OrderLine line(double quantity, List<OrderModifier> modifiers) => OrderLine(
        productId: 1,
        name: 'Burger',
        quantity: quantity,
        unitPrice: 50,
        modifiers: modifiers,
      );

  OrderModifier mod(int id, String name, double price, {double quantity = 1}) =>
      OrderModifier(
          modifierId: id, name: name, quantity: quantity, unitPrice: price);

  Widget screen(List<Order> orders) => MaterialApp(
        home: ModifierReportScreen(
          orders: orders,
          formatAmount: (v) => v.toStringAsFixed(2),
        ),
      );

  testWidgets('a range with no add-ons says so', (t) async {
    await t.pumpWidget(screen([sale([line(1, const [])])]));
    expect(find.byKey(const Key('modifiers-empty-state')), findsOneWidget);
  });

  testWidgets('modifiers aggregate by id across orders and line quantities',
      (t) async {
    await t.pumpWidget(screen([
      sale([line(2, [mod(7, 'Extra cheese', 5)])]),
      sale([line(1, [mod(7, 'Extra cheese', 5)])]),
    ]));

    // Two burgers plus one: three cheeses at 5 each.
    expect(find.text('15.00'), findsWidgets);
    expect(find.textContaining('3 ·'), findsOneWidget);
    final rows = t.widget<Column>(find.byKey(const Key('modifier-list')));
    expect(rows.children.length, 1);
  });

  testWidgets('a free modifier is listed rather than dropped', (t) async {
    await t.pumpWidget(screen([
      sale([line(1, [mod(9, 'No onions', 0)])]),
    ]));

    expect(find.text('No onions'), findsOneWidget);
    expect(find.text('0.00'), findsWidgets);
  });

  testWidgets('the priciest modifier leads the list', (t) async {
    await t.pumpWidget(screen([
      sale([
        line(1, [mod(1, 'Bacon', 8), mod(2, 'Sauce', 1)]),
      ]),
    ]));

    final rows = t.widget<Column>(find.byKey(const Key('modifier-list')));
    final first = rows.children.first as ListTile;
    expect((first.title! as Text).data, 'Bacon');
  });
}
