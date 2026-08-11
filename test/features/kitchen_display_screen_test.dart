import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/kitchen/kitchen_display_screen.dart';

void main() {
  Order ticket({required KitchenStatus status, required String table}) => Order(
        deviceId: 'kds-1',
        cashierId: 'sara',
        state: OrderState.held,
        tableLabel: table,
        kitchenStatus: status,
        lines: [
          OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 250),
        ],
      );

  testWidgets('renders one card per active ticket', (t) async {
    final orders = [
      ticket(status: KitchenStatus.pending, table: 'T1'),
      ticket(status: KitchenStatus.preparing, table: 'T2'),
    ];

    await t.pumpWidget(MaterialApp(
      home: KitchenDisplayScreen(
        load: () => orders,
        onStatus: (uuid, status) {},
      ),
    ));

    expect(find.byKey(Key('kds-${orders[0].uuid}')), findsOneWidget);
    expect(find.byKey(Key('kds-${orders[1].uuid}')), findsOneWidget);
  });

  testWidgets('tapping Start on a pending ticket advances it to preparing', (t) async {
    final orders = [
      ticket(status: KitchenStatus.pending, table: 'T1'),
      ticket(status: KitchenStatus.preparing, table: 'T2'),
    ];
    String? advancedUuid;
    KitchenStatus? advancedStatus;

    await t.pumpWidget(MaterialApp(
      home: KitchenDisplayScreen(
        load: () => orders,
        onStatus: (uuid, status) {
          advancedUuid = uuid;
          advancedStatus = status;
        },
      ),
    ));

    await t.tap(find.byKey(Key('kds-${orders[0].uuid}-start')));
    await t.pumpAndSettle();

    expect(advancedUuid, orders[0].uuid);
    expect(advancedStatus, KitchenStatus.preparing);
  });

  testWidgets('tapping Ready on a preparing ticket advances it to ready', (t) async {
    final orders = [
      ticket(status: KitchenStatus.pending, table: 'T1'),
      ticket(status: KitchenStatus.preparing, table: 'T2'),
    ];
    String? advancedUuid;
    KitchenStatus? advancedStatus;

    await t.pumpWidget(MaterialApp(
      home: KitchenDisplayScreen(
        load: () => orders,
        onStatus: (uuid, status) {
          advancedUuid = uuid;
          advancedStatus = status;
        },
      ),
    ));

    await t.tap(find.byKey(Key('kds-${orders[1].uuid}-ready')));
    await t.pumpAndSettle();

    expect(advancedUuid, orders[1].uuid);
    expect(advancedStatus, KitchenStatus.ready);
  });

  testWidgets('shows an empty state when there are no active tickets', (t) async {
    await t.pumpWidget(MaterialApp(
      home: KitchenDisplayScreen(
        load: () => const [],
        onStatus: (uuid, status) {},
      ),
    ));

    expect(find.text('No active tickets'), findsOneWidget);
  });
}
