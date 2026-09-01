import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/reports/today_glance_card.dart';

void main() {
  final now = DateTime(2026, 8, 14, 15);

  Order sale(double amount, {List<OrderPayment> payments = const [], int daysAgo = 0}) {
    final at = now.subtract(Duration(days: daysAgo));
    return Order(
      deviceId: 'd',
      cashierId: 'sara',
      type: OrderType.takeaway,
      createdAt: DateTime(at.year, at.month, at.day, 12).toUtc(),
      lines: [
        OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: amount)
      ],
      payments: [...payments],
    );
  }

  Widget card(List<Order> orders,
          {int? openTables, Set<int> cashTenderIds = const {}}) =>
      MaterialApp(
        home: Scaffold(
          body: TodayGlanceCard(
            allOrders: orders,
            formatAmount: (v) => v.toStringAsFixed(2),
            openTables: openTables,
            now: now,
            cashTenderIds: cashTenderIds,
          ),
        ),
      );

  String valueOf(WidgetTester t, String key) => t
      .widgetList<Text>(
          find.descendant(of: find.byKey(Key(key)), matching: find.byType(Text)))
      .last
      .data!;

  testWidgets('an empty shop day renders zeroes, not an error', (t) async {
    await t.pumpWidget(card(const []));

    expect(find.byKey(const Key('today-glance')), findsOneWidget);
    expect(valueOf(t, 'glance-orders'), '0');
    expect(valueOf(t, 'glance-gross'), '0.00');
  });

  testWidgets('only today counts, and cash is split from other tenders',
      (t) async {
    await t.pumpWidget(card([
      sale(100),
      sale(60, payments: [
        OrderPayment(methodId: 2, amount: 60, label: 'Card'),
      ]),
      sale(999, daysAgo: 1),
    ]));

    expect(valueOf(t, 'glance-orders'), '2');
    expect(valueOf(t, 'glance-gross'), '160.00');
    // An untendered sale is cash, the same way the shift read books it.
    expect(valueOf(t, 'glance-cash'), '100.00');
    expect(valueOf(t, 'glance-other'), '60.00');
  });

  testWidgets('open tables show when the shop has a floor', (t) async {
    await t.pumpWidget(card(const [], openTables: 3));
    expect(valueOf(t, 'glance-tables'), '3');
  });

  testWidgets('no floor means no tables tile', (t) async {
    await t.pumpWidget(card(const []));
    expect(find.byKey(const Key('glance-tables')), findsNothing);
  });

  testWidgets('a cash journal that is not called Cash is still cash', (t) async {
    // The tenders are the shop's own journals now, so the one that takes the
    // notes is called "Cash drawer", or its name is in Arabic. A card matching on
    // the word would report a whole night's takings as card.
    final o = Order(deviceId: 'till-1', cashierId: 'sara')
      ..lines.add(OrderLine(
          productId: 1, name: 'Tea', quantity: 1, unitPrice: 100))
      ..payments = [
        const OrderPayment(methodId: -7, amount: 100, label: 'Cash drawer'),
      ]
      ..state = OrderState.paid;

    await t.pumpWidget(card([o], cashTenderIds: const {-7}));
    expect(valueOf(t, 'glance-cash'), '100.00');
    expect(valueOf(t, 'glance-other'), '0.00');
  });

  testWidgets('a till that has never pulled still reads the label', (t) async {
    final o = Order(deviceId: 'till-1', cashierId: 'sara')
      ..lines.add(OrderLine(
          productId: 1, name: 'Tea', quantity: 1, unitPrice: 40))
      ..payments = [const OrderPayment(methodId: 1, amount: 40, label: 'Cash')]
      ..state = OrderState.paid;

    await t.pumpWidget(card([o]));
    expect(valueOf(t, 'glance-cash'), '40.00');
  });
}
