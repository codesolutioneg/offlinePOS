import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/delivery.dart';
import 'package:offline_pos/domain/delivery_bulletin.dart';
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
    VoidCallback? onShiftOrders,
    List<FloorAction> actions = const [],
    List<Driver> drivers = const [],
    void Function(Order, Driver?)? onAssignDriver,
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
        onShiftOrders: onShiftOrders,
        actions: actions,
        drivers: drivers,
        onAssignDriver: onAssignDriver,
      ),
    ));
  }

  testWidgets('the shift orders button sits in the header and opens the list',
      (t) async {
    var opened = 0;
    await pump(t, onShiftOrders: () => opened++);
    await t.tap(find.byKey(const Key('delivery-home-shift-orders')));
    expect(opened, 1);
  });

  testWidgets('no callback, no shift orders button', (t) async {
    await pump(t);
    expect(find.byKey(const Key('delivery-home-shift-orders')), findsNothing);
  });

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

  testWidgets('the Bulletin board carries the delivery numbers', (t) async {
    t.view.physicalSize = const Size(1366, 768);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final a = bag(OrderType.storeDelivery, 'Nadia');
    await t.pumpWidget(MaterialApp(
      home: DeliveryHomeScreen(
        types: const [OrderType.storeDelivery],
        parked: [a],
        formatAmount: (v) => v.toStringAsFixed(2),
        onOpenType: (_) {},
        onResume: (_) {},
        bulletin: DeliveryBulletin.from(held: [a], closedToday: const []),
      ),
    ));
    expect(find.byKey(const Key('delivery-bulletin')), findsOneWidget);
    expect(
        t.widget<Text>(find.byKey(const Key('bulletin-waiting-value'))).data,
        '1');
    expect(
        t.widget<Text>(find.byKey(const Key('bulletin-no-driver-value'))).data,
        '1');
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

  testWidgets('Driver on a waiting card opens the assign sheet without resume',
      (t) async {
    final a = bag(OrderType.storeDelivery, 'Nadia');
    final driver = Driver(id: 'd1', name: 'mostafa', phone: '01000000');
    Order? assignedOrder;
    Driver? assignedDriver;
    var resumed = 0;
    await pump(
      t,
      parked: [a],
      drivers: [driver],
      onResume: (_) => resumed++,
      onAssignDriver: (o, d) {
        assignedOrder = o;
        assignedDriver = d;
      },
    );
    await t.tap(find.byKey(Key('delivery-home-assign-driver-${a.uuid}')));
    await t.pumpAndSettle();
    expect(resumed, 0);
    expect(find.byKey(const Key('delivery-home-driver-dialog')), findsOneWidget);
    expect(find.text('mostafa'), findsWidgets);
    await t.tap(find.byKey(Key('delivery-home-driver-${driver.id}')));
    await t.pumpAndSettle();
    expect(assignedOrder, a);
    expect(assignedDriver?.id, 'd1');
  });

  testWidgets('driver dialog search filters by name', (t) async {
    final a = bag(OrderType.storeDelivery, 'Nadia');
    final mostafa = Driver(id: 'd1', name: 'mostafa', phone: '01000000');
    final yaser = Driver(id: 'd2', name: 'yaser');
    Driver? picked;
    await pump(
      t,
      parked: [a],
      drivers: [mostafa, yaser],
      onAssignDriver: (_, d) => picked = d,
    );
    await t.tap(find.byKey(Key('delivery-home-assign-driver-${a.uuid}')));
    await t.pumpAndSettle();
    await t.enterText(
        find.byKey(const Key('delivery-home-driver-search')), 'yas');
    await t.pumpAndSettle();
    expect(find.byKey(Key('delivery-home-driver-${yaser.id}')), findsOneWidget);
    expect(
        find.byKey(Key('delivery-home-driver-${mostafa.id}')), findsNothing);
    await t.tap(find.byKey(Key('delivery-home-driver-${yaser.id}')));
    await t.pumpAndSettle();
    expect(picked?.id, 'd2');
  });
}
