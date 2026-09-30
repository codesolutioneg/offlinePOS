import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/schema.dart';
import 'package:offline_pos/core/db/stress_purge.dart';
import 'package:offline_pos/core/lan/lan_event.dart';
import 'package:offline_pos/core/lan/lan_number_desk.dart';
import 'package:offline_pos/core/lan/lan_transport.dart';
import 'package:offline_pos/domain/order.dart';

import '../db/sqlite_loader.dart';
import 'shop.dart';

/// Two tills paying inside one replication window used to hand out the same
/// order number (the Stress Lab caught #373 on both). The primary now numbers
/// for the secondaries off its own counter.
void main() {
  late TestShop shop;
  late TestTill a;
  late TestTill b;

  setUpAll(useSystemSqlite);
  setUp(() {
    shop = TestShop();
    a = shop.add('till-a');
    b = shop.add('till-b');
    shop.introduceAll();
  });
  tearDown(() => shop.close());

  String ownNumber(TestTill till) =>
      till.settings.nextOrderNumber(till.deviceId, atLeast: till.orders.orderNumberFloor());

  final body = jsonEncode({'device_id': 'till-b', 'schema': Schema.version});
  String? stamp() =>
      b.credential.stamp(method: 'POST', path: LanProtocol.numberPath, body: body);

  group('the primary hands out order numbers', () {
    late LanNumberDesk desk;
    var primary = true;
    late LanProtocol protocol;

    setUp(() {
      primary = true;
      desk = LanNumberDesk(deviceId: 'till-a', settings: a.settings, orders: a.orders);
      protocol = LanProtocol(
        deviceId: 'till-a',
        log: a.log,
        applier: a.applier,
        credential: a.credential,
        numbers: () => primary ? desk : null,
      );
    });

    String ask() =>
        protocol.handlePost(LanProtocol.numberPath, body, auth: stamp()).body['order_no']
            as String;

    test('only the primary answers', () {
      primary = false;
      expect(protocol.handlePost(LanProtocol.numberPath, body, auth: stamp()).status, 409);
    });

    test('an unpaired device gets no number', () {
      expect(protocol.handlePost(LanProtocol.numberPath, body).status, 401);
    });

    test('its own sales and the secondary\'s come off one counter', () {
      final first = ask();
      final own = ownNumber(a);
      final second = ask();

      expect(int.parse(own), int.parse(first) + 1);
      expect(int.parse(second), int.parse(own) + 1);
    });

    test('two tills paying at once never share a number', () async {
      final supply = LanNumberSupply(ask: () async => ask());
      final numbers = <String>[];
      supply.prepare();
      for (var i = 0; i < 50; i++) {
        await supply.settled;
        numbers.add(supply.take()!);
        supply.prepare();
        numbers.add(ownNumber(a));
      }

      expect(numbers.toSet(), hasLength(100));
    });
  });

  group('the secondary\'s reserved number', () {
    test('with nothing reserved the till numbers locally', () {
      expect(LanNumberSupply(ask: () async => '7').take(), isNull);
    });

    test('a reserved number is used once', () async {
      final supply = LanNumberSupply(ask: () async => '7')..prepare();
      await supply.settled;

      expect(supply.take(), '7');
      expect(supply.take(), isNull);
    });

    test('a primary that cannot be asked leaves nothing reserved', () async {
      final supply = LanNumberSupply(ask: () async => throw StateError('down'))..prepare();
      await supply.settled;

      expect(supply.take(), isNull);
    });

    test('a number held over a quiet spell is swapped for a fresh one', () async {
      var now = DateTime.utc(2026, 1, 1, 12);
      var asks = 0;
      final supply = LanNumberSupply(ask: () async => '${++asks}', now: () => now);
      supply.prepare();
      await supply.settled;
      supply.prepare();
      await supply.settled;
      expect(asks, 1, reason: 'a fresh number is kept');

      now = now.add(supply.freshFor + const Duration(seconds: 1));
      supply.prepare();
      await supply.settled;

      expect(supply.take(), '2');
    });
  });

  group('Stress Lab cleanup reaches every till', () {
    Order paid(String device, {String? note}) =>
        Order(deviceId: device, cashierId: 'ana', note: note)
          ..state = OrderState.paid
          ..lines.add(OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 100));

    test('a cleanup on one till drops the lab orders on the other, and nothing else',
        () async {
      final real = paid('till-b');
      a.orders.save(paid('till-a', note: kStressNote));
      b.orders.save(paid('till-b', note: kStressNote));
      b.orders.save(real);
      await shop.settle();
      expect(a.orders.count, 3);
      expect(b.orders.count, 3);

      purgeStressOrders(a.db);
      a.fabric.publish(LanEventKind.stressCleanup, 'stress-cleanup', {'note': kStressNote});
      await shop.settle();

      for (final till in [a, b]) {
        expect(till.orders.count, 1, reason: till.deviceId);
        expect(till.orders.byUuid(real.uuid)?.state, OrderState.paid, reason: till.deviceId);
      }
    });
  });
}
