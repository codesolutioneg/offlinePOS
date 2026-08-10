import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/orders/open_orders_screen.dart';

void main() {
  Order held({required String table, required int guestCount}) => Order(
        deviceId: 'till-1',
        cashierId: 'sara',
        state: OrderState.held,
        tableLabel: table,
        guestCount: guestCount,
        lines: [
          OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 250),
          OrderLine(productId: 2, name: 'Water', quantity: 2, unitPrice: 10),
        ],
      );

  testWidgets('lists every held order with a recall key', (t) async {
    final orders = [
      held(table: 'T1', guestCount: 2),
      held(table: 'T2', guestCount: 4),
    ];
    await t.pumpWidget(MaterialApp(
      home: OpenOrdersScreen(
        orders: orders,
        formatAmount: (v) => v.toStringAsFixed(2),
        onRecall: (_) {},
      ),
    ));

    expect(find.byKey(Key('recall-${orders[0].uuid}')), findsOneWidget);
    expect(find.byKey(Key('recall-${orders[1].uuid}')), findsOneWidget);
  });

  testWidgets('tapping a card recalls that order and closes the screen', (t) async {
    final orders = [
      held(table: 'T1', guestCount: 2),
      held(table: 'T2', guestCount: 4),
    ];
    Order? recalled;

    await t.pumpWidget(MaterialApp(
      home: Navigator(
        onGenerateRoute: (settings) => MaterialPageRoute(
          builder: (_) => OpenOrdersScreen(
            orders: orders,
            formatAmount: (v) => v.toStringAsFixed(2),
            onRecall: (order) => recalled = order,
          ),
        ),
      ),
    ));

    await t.tap(find.byKey(Key('recall-${orders[1].uuid}')));
    await t.pumpAndSettle();

    expect(recalled, orders[1]);
  });

  testWidgets('shows an empty state when there are no open tables', (t) async {
    await t.pumpWidget(MaterialApp(
      home: OpenOrdersScreen(
        orders: const [],
        formatAmount: (v) => v.toStringAsFixed(2),
        onRecall: (_) {},
      ),
    ));

    expect(find.text('No open tables'), findsOneWidget);
  });
}
