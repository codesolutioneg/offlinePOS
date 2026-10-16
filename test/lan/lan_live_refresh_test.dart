import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/lan/lan_cart_board.dart';
import 'package:offline_pos/core/lan/lan_event.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/kitchen/kitchen_display_screen.dart';

import '../db/sqlite_loader.dart';
import 'shop.dart';

void main() {
  setUpAll(useSystemSqlite);

  late TestShop shop;
  setUp(() => shop = TestShop());
  tearDown(() => shop.close());

  LanEvent arrival(Order order, {required int seq}) => LanEvent(
        kind: LanEventKind.orderUpsert,
        originDeviceId: 'till-a',
        seq: seq,
        recordUuid: order.uuid,
        payload: order.toMap(),
        at: DateTime.now().toUtc(),
      );

  test('an order from another till tells the screens at once', () async {
    final till = shop.add('till-b');
    var told = 0;
    final sub = till.settings.sharedChanges.listen((_) => told++);
    addTearDown(sub.cancel);

    till.applier.applyAll('till-a', [arrival(heldOrder('till-a'), seq: 1)], highSeq: 1);
    await Future<void>.delayed(Duration.zero);

    expect(told, 1);
  });

  test('a page that writes nothing new tells nobody', () async {
    final till = shop.add('till-b');
    final order = heldOrder('till-a');
    till.applier.applyAll('till-a', [arrival(order, seq: 1)], highSeq: 1);
    var told = 0;
    final sub = till.settings.sharedChanges.listen((_) => told++);
    addTearDown(sub.cancel);

    till.applier.applyAll('till-a', const [], highSeq: 1);
    await Future<void>.delayed(Duration.zero);

    expect(told, 0);
  });

  test('a customer-display cart does not redraw the floor on every tap', () async {
    final till = shop.add('till-b');
    var told = 0;
    final sub = till.settings.sharedChanges.listen((_) => told++);
    addTearDown(sub.cancel);

    final now = DateTime.now().toUtc();
    till.applier.applyAll(
      'till-a',
      [
        LanEvent(
          kind: LanEventKind.cartDisplay,
          originDeviceId: 'till-a',
          seq: 1,
          recordUuid: 'till-a',
          payload: LanCartSnapshot(deviceId: 'till-a', lines: const [], total: 0, at: now)
              .toMap(),
          at: now,
        ),
      ],
      highSeq: 1,
    );
    await Future<void>.delayed(Duration.zero);

    expect(told, 0);
  });

  testWidgets('the kitchen board reloads when another till\'s ticket lands', (t) async {
    final changes = StreamController<void>.broadcast();
    addTearDown(changes.close);
    final tickets = <Order>[];

    await t.pumpWidget(MaterialApp(
      home: KitchenDisplayScreen(
        load: () => List.of(tickets),
        onStatus: (_, _) {},
        changes: changes.stream,
      ),
    ));
    final order = heldOrder('till-a');
    tickets.add(order);
    expect(find.byKey(Key('kds-${order.uuid}')), findsNothing);

    changes.add(null);
    await t.pump();

    expect(find.byKey(Key('kds-${order.uuid}')), findsOneWidget);
  });
}
