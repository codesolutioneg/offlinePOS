import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/orders/open_orders_screen.dart';

/// The deliveries in the open-orders list. A delivery has no table to tap on the
/// floor, so this is the only place the bags waiting can be read as a group: who
/// they are for, who is carrying them, and how long they have been sitting.
void main() {
  Order table(String label) => Order(
        deviceId: 'till-1',
        cashierId: 'sara',
        state: OrderState.held,
        tableLabel: label,
        lines: [OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 250)],
      );

  Order delivery({
    String name = 'Nadia',
    String? driver,
    String? channel,
    Duration ago = const Duration(minutes: 25),
  }) =>
      Order(
        deviceId: 'till-1',
        cashierId: 'sara',
        state: OrderState.held,
        type: OrderType.delivery,
        customerName: name,
        driverName: driver,
        deliveryChannel: channel,
        createdAt: DateTime.now().toUtc().subtract(ago),
        lines: [OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 250)],
      );

  Future<void> show(WidgetTester t, List<Order> orders) => t.pumpWidget(MaterialApp(
        home: OpenOrdersScreen(
          orders: orders,
          formatAmount: (v) => v.toStringAsFixed(2),
          onRecall: (_) {},
        ),
      ));

  testWidgets('the delivery filter hides the tables', (t) async {
    final deliveryOrder = delivery();
    await show(t, [table('T1'), deliveryOrder]);

    await t.tap(find.byKey(const Key('open-filter-delivery')));
    await t.pumpAndSettle();

    expect(find.byKey(Key('open-order-${deliveryOrder.uuid}')), findsOneWidget);
    expect(find.text('T1'), findsNothing);
  });

  testWidgets('a shop with no deliveries is not shown the filter at all', (t) async {
    await show(t, [table('T1')]);
    expect(find.byKey(const Key('open-filter-delivery')), findsNothing);
  });

  testWidgets('a delivery card leads with the customer, the driver and the wait',
      (t) async {
    await show(t, [delivery(driver: 'Hany', channel: 'Talabat')]);

    expect(find.text('Nadia'), findsOneWidget);
    expect(find.textContaining('Hany'), findsOneWidget);
    expect(find.textContaining('Talabat'), findsOneWidget);
    expect(find.textContaining('25m'), findsOneWidget);
  });

  testWidgets('a delivery nobody has picked up says so', (t) async {
    await show(t, [delivery()]);
    expect(find.textContaining('No driver yet'), findsOneWidget);
  });

  testWidgets('an hour-old bag reads in hours', (t) async {
    await show(t, [delivery(ago: const Duration(hours: 1, minutes: 5))]);
    expect(find.textContaining('1h 5m'), findsOneWidget);
  });

  testWidgets('the last delivery leaving gives the cashier the tables back',
      (t) async {
    final gone = delivery();
    final t1 = table('T1');
    await show(t, [t1, gone]);
    await t.tap(find.byKey(const Key('open-filter-delivery')));
    await t.pumpAndSettle();
    expect(find.byKey(Key('open-order-${t1.uuid}')), findsNothing);

    // The bag goes out and the list refreshes without it. The filter goes with it
    // rather than leaving an empty screen with no way back.
    await show(t, [t1]);

    expect(find.byKey(Key('open-order-${gone.uuid}')), findsNothing);
    expect(find.byKey(Key('open-order-${t1.uuid}')), findsOneWidget);
  });

  testWidgets('a table card still reads by table, cashier and time', (t) async {
    final t1 = table('T1');
    await show(t, [t1, delivery()]);

    expect(find.byKey(Key('open-order-${t1.uuid}')), findsOneWidget);
    expect(find.textContaining('sara'), findsOneWidget,
        reason: 'a dine-in tab is still read by who is running it');
  });
}
