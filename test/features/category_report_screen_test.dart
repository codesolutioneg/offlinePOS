import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/reports/category_report_screen.dart';

Order _order({required List<OrderLine> lines}) => Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      lines: lines,
    );

void main() {
  const categories = [
    Category(id: 1, name: 'Mains'),
    Category(id: 2, name: 'Drinks'),
  ];

  Widget app(List<Order> orders, {List<Category> cats = categories}) => MaterialApp(
        home: CategoryReportScreen(
          orders: orders,
          categories: cats,
          formatAmount: (v) => v.toStringAsFixed(2),
        ),
      );

  testWidgets('shows empty state when there are no orders', (tester) async {
    await tester.pumpWidget(app(const []));

    expect(find.text('Category performance'), findsOneWidget);
    expect(find.text('No orders'), findsOneWidget);
  });

  testWidgets('ranks the category with the most revenue first', (tester) async {
    // Mains: 1 unit at 200 = 200 revenue.
    // Drinks: 10 units at 5 each = 50 revenue.
    final orders = [
      _order(lines: [
        OrderLine(productId: 1, name: 'Margherita', quantity: 1, unitPrice: 200, categoryId: 1),
        OrderLine(productId: 2, name: 'Soda', quantity: 4, unitPrice: 5, categoryId: 2),
      ]),
      _order(lines: [
        OrderLine(productId: 2, name: 'Soda', quantity: 6, unitPrice: 5, categoryId: 2),
      ]),
    ];

    await tester.pumpWidget(app(orders));

    final list = find.byKey(const Key('category-list'));
    expect(list, findsOneWidget);

    final names = tester.widgetList<Text>(
      find.descendant(of: list, matching: find.byType(Text)),
    );
    expect(names.first.data, 'Mains');

    expect(find.text('200.00'), findsOneWidget);
    expect(find.text('50.00'), findsOneWidget);
    expect(find.byIcon(Icons.star), findsOneWidget);
  });

  testWidgets('groups lines with no category or an unknown category id as Uncategorised',
      (tester) async {
    final orders = [
      _order(lines: [
        OrderLine(productId: 3, name: 'Mystery item', quantity: 2, unitPrice: 10),
        OrderLine(productId: 4, name: 'Ghost item', quantity: 1, unitPrice: 5, categoryId: 99),
      ]),
    ];

    await tester.pumpWidget(app(orders));

    expect(find.text('Uncategorised'), findsOneWidget);
    expect(find.text('25.00'), findsOneWidget);
  });
}
