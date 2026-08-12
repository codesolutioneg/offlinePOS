import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/theme/app_colors.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/kitchen/kitchen_display_screen.dart';

void main() {
  Order ticket({
    required KitchenStatus status,
    required String table,
    DateTime? createdAt,
  }) =>
      Order(
        deviceId: 'kds-1',
        cashierId: 'sara',
        state: OrderState.held,
        tableLabel: table,
        kitchenStatus: status,
        createdAt: createdAt,
        lines: [
          OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 250),
        ],
      );

  Color borderColorOf(WidgetTester t, String uuid) {
    final card = t.widget<Card>(find.descendant(
      of: find.byKey(Key('kds-$uuid')),
      matching: find.byType(Card),
    ));
    return (card.shape as RoundedRectangleBorder).side.color;
  }

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

  testWidgets('cards border colour follows the SLA age thresholds', (t) async {
    final now = DateTime.now();
    final orders = [
      ticket(status: KitchenStatus.pending, table: 'T1', createdAt: now),
      ticket(status: KitchenStatus.pending, table: 'T2', createdAt: now.subtract(const Duration(minutes: 7))),
      ticket(status: KitchenStatus.pending, table: 'T3', createdAt: now.subtract(const Duration(minutes: 12))),
    ];

    await t.pumpWidget(MaterialApp(
      home: KitchenDisplayScreen(
        load: () => orders,
        onStatus: (uuid, status) {},
      ),
    ));

    expect(borderColorOf(t, orders[0].uuid), AppColors.success);
    expect(borderColorOf(t, orders[1].uuid), AppColors.warning);
    expect(borderColorOf(t, orders[2].uuid), AppColors.error);
  });

  testWidgets('the per-card timer and the app bar clock tick every second', (t) async {
    // A controllable clock: the periodic timer fires on fake-async virtual time
    // (driven by `pump`), but it reads real wall-clock time by default, which
    // barely moves during a fast test run. Injecting the clock makes each tick
    // deterministic instead of racing real time.
    var fakeNow = DateTime(2024, 1, 1, 10, 0, 0);
    final orders = [
      ticket(status: KitchenStatus.pending, table: 'T1', createdAt: fakeNow),
    ];

    await t.pumpWidget(MaterialApp(
      home: KitchenDisplayScreen(
        load: () => orders,
        onStatus: (uuid, status) {},
        nowFn: () => fakeNow,
      ),
    ));

    final timerFinder = find.byKey(Key('kds-${orders[0].uuid}-timer'));
    final before = t.widget<Text>(find.descendant(of: timerFinder, matching: find.byType(Text))).data;
    final clockBefore = t.widget<Text>(find.byKey(const Key('kds-clock'))).data;
    expect(before, '00:00');

    fakeNow = fakeNow.add(const Duration(seconds: 3));
    await t.pump(const Duration(seconds: 1));

    final after = t.widget<Text>(find.descendant(of: timerFinder, matching: find.byType(Text))).data;
    final clockAfter = t.widget<Text>(find.byKey(const Key('kds-clock'))).data;

    expect(after, '00:03');
    expect(clockAfter, isNot(clockBefore));
  });

  testWidgets('the grid column count adapts to the available width', (t) async {
    final orders = [
      ticket(status: KitchenStatus.pending, table: 'T1'),
      ticket(status: KitchenStatus.preparing, table: 'T2'),
    ];

    Future<int> columnsAt(Size size) async {
      await t.binding.setSurfaceSize(size);
      await t.pumpWidget(MaterialApp(
        home: KitchenDisplayScreen(
          load: () => orders,
          onStatus: (uuid, status) {},
        ),
      ));
      await t.pump();
      final grid = t.widget<GridView>(find.byKey(const Key('kds-grid')));
      final delegate = grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      return delegate.crossAxisCount;
    }

    addTearDown(() => t.binding.setSurfaceSize(null));

    expect(await columnsAt(const Size(650, 800)), 1);
    expect(await columnsAt(const Size(900, 800)), 2);
    expect(await columnsAt(const Size(1300, 800)), 3);
    expect(await columnsAt(const Size(1600, 800)), 4);
  });
}
