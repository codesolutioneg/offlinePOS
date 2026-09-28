import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/orders/delivery_home_screen.dart';
import 'package:offline_pos/features/tables/floor_action_bar.dart';

void main() {
  Order bag(OrderType type, String name) => Order(
        deviceId: 'till-1',
        cashierId: 'sara',
        type: type,
        customerName: name,
      )..lines.add(
          OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 100));

  Future<void> pump(
    WidgetTester t, {
    List<Order> parked = const [],
    void Function(OrderType)? onOpenType,
    void Function(Order)? onResume,
    bool Function()? guard,
    VoidCallback? onBack,
    List<FloorAction> actions = const [],
  }) async {
    t.view.physicalSize = const Size(1366, 768);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: DeliveryHomeScreen(
        types: const [
          OrderType.deliveryFromCompany,
          OrderType.storeDelivery,
          OrderType.carDelivery,
        ],
        parked: parked,
        formatAmount: (v) => v.toStringAsFixed(2),
        onOpenType: onOpenType ?? (_) {},
        onResume: onResume ?? (_) {},
        guard: guard,
        onBack: onBack,
        actions: actions,
      ),
    ));
  }

  testWidgets('a big button per delivery kind opens that kind', (t) async {
    final opened = <OrderType>[];
    await pump(t, onOpenType: opened.add);
    expect(find.byKey(const Key('delivery-home-deliveryFromCompany')),
        findsOneWidget);
    expect(find.byKey(const Key('delivery-home-carDelivery')), findsOneWidget);
    await t.tap(find.byKey(const Key('delivery-home-storeDelivery')));
    expect(opened, [OrderType.storeDelivery]);
    expect(find.text('No deliveries waiting.'), findsOneWidget);
  });

  testWidgets('waiting bags are listed and a tap resumes one', (t) async {
    final a = bag(OrderType.storeDelivery, 'Nadia');
    final b = bag(OrderType.carDelivery, 'Omar');
    final resumed = <Order>[];
    await pump(t, parked: [a, b], onResume: resumed.add);
    expect(find.text('Nadia'), findsOneWidget);
    expect(find.text('Omar'), findsOneWidget);
    await t.tap(find.byKey(Key('delivery-home-resume-${b.uuid}')));
    expect(resumed, [b]);
  });

  testWidgets('the guard refuses starting or resuming', (t) async {
    final a = bag(OrderType.storeDelivery, 'Nadia');
    final opened = <Object>[];
    await pump(t,
        parked: [a],
        guard: () => false,
        onOpenType: opened.add,
        onResume: opened.add);
    await t.tap(find.byKey(const Key('delivery-home-storeDelivery')));
    await t.tap(find.byKey(Key('delivery-home-resume-${a.uuid}')));
    expect(opened, isEmpty);
  });

  testWidgets('a delivery-only home has no way back to the tables',
      (t) async {
    await pump(t);
    expect(find.byKey(const Key('delivery-home-back')), findsNothing);
    var back = 0;
    await pump(t, onBack: () => back++);
    await t.tap(find.byKey(const Key('delivery-home-back')));
    expect(back, 1);
  });

  testWidgets('carries the station bar', (t) async {
    var taps = 0;
    await pump(t, actions: [
      FloorAction(
          id: 'session',
          label: 'Session',
          icon: Icons.point_of_sale,
          color: Colors.teal,
          onTap: () => taps++),
    ]);
    await t.tap(find.byKey(const Key('delivery-action-session')));
    expect(taps, 1);
  });
}
