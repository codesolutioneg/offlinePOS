import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/delivery.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/reports/driver_delivery_report_screen.dart';

void main() {
  testWidgets('picking a driver shows their held deliveries', (t) async {
    final driver = Driver(id: 'd1', name: 'yaser');
    final held = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      type: OrderType.storeDelivery,
      state: OrderState.held,
      customerName: 'Nadia',
      driverId: driver.id,
      driverName: driver.name,
    )..lines.add(
        OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 100));

    await t.pumpWidget(MaterialApp(
      home: DriverDeliveryReportScreen(
        orders: [held],
        drivers: [driver],
        formatAmount: (v) => v.toStringAsFixed(2),
      ),
    ));
    await t.pumpAndSettle();

    expect(find.text('Pick a driver'), findsWidgets);
    await t.tap(find.byKey(const Key('driver-report-picker-none')));
    await t.pumpAndSettle();
    await t.tap(find.text('yaser').last);
    await t.pumpAndSettle();

    expect(find.text('Nadia'), findsOneWidget);
    expect(find.byKey(Key('driver-account-order-${held.uuid}')), findsOneWidget);
  });

  testWidgets('All drivers shows every assigned bag', (t) async {
    final a = Driver(id: 'd1', name: 'yaser');
    final b = Driver(id: 'd2', name: 'mostafa');
    final oa = Order(
      deviceId: 't',
      cashierId: 'c',
      type: OrderType.storeDelivery,
      state: OrderState.paid,
      customerName: 'A',
      driverId: a.id,
      driverName: a.name,
    )..lines.add(
        OrderLine(productId: 1, name: 'X', quantity: 1, unitPrice: 10));
    final ob = Order(
      deviceId: 't',
      cashierId: 'c',
      type: OrderType.storeDelivery,
      state: OrderState.paid,
      customerName: 'B',
      driverId: b.id,
      driverName: b.name,
    )..lines.add(
        OrderLine(productId: 1, name: 'Y', quantity: 1, unitPrice: 20));

    await t.pumpWidget(MaterialApp(
      home: DriverDeliveryReportScreen(
        orders: [oa, ob],
        drivers: [a, b],
        formatAmount: (v) => v.toStringAsFixed(2),
      ),
    ));
    await t.tap(find.byKey(const Key('driver-report-picker-none')));
    await t.pumpAndSettle();
    await t.tap(find.text('All drivers').last);
    await t.pumpAndSettle();

    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
  });
}
