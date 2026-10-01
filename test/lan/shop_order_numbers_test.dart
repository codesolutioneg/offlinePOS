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

    List<String> askMany(int count) {
      final many = jsonEncode(
          {'device_id': 'till-b', 'schema': Schema.version, 'count': count});
      final reply = protocol.handlePost(LanProtocol.numberPath, many,
          auth: b.credential
              .stamp(method: 'POST', path: LanProtocol.numberPath, body: many));
      return (reply.body['order_nos'] as List).cast<String>();
    }

    test('an older secondary asking without a count gets one number', () {
      final reply = protocol.handlePost(LanProtocol.numberPath, body, auth: stamp());

      expect(reply.body['order_nos'], [reply.body['order_no']]);
    });

    test('a reserve comes off the same counter as the primary\'s own sales', () {
      final reserve = askMany(4);
      final own = ownNumber(a);

      expect(reserve.map(int.parse), [for (var i = 0; i < 4; i++) int.parse(reserve.first) + i]);
      expect(int.parse(own), int.parse(reserve.last) + 1);
      expect(askMany(500), hasLength(LanProtocol.maxNumbersPerAsk));
    });

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
      final supply = LanNumberSupply(ask: (n) async => askMany(n));
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

    test('a split into three checks takes all three off the primary', () async {
      final supply = LanNumberSupply(ask: (n) async => askMany(n))..prepare();
      await supply.settled;

      // One tap, three checks, no time for an ask in between.
      final checks = [supply.take(), supply.take(), supply.take()];
      final own = ownNumber(a);

      expect(checks, everyElement(isNotNull));
      expect({...checks, own}, hasLength(4));
    });
  });

  group('the secondary\'s reserve', () {
    var next = 0;
    Future<List<String>> counter(int n) async => [for (var i = 0; i < n; i++) '${++next}'];
    setUp(() => next = 0);

    test('with nothing reserved the till numbers locally', () {
      expect(LanNumberSupply(ask: counter).take(), isNull);
    });

    test('each reserved number is used once, oldest first', () async {
      final supply = LanNumberSupply(ask: counter, batch: 3)..prepare();
      await supply.settled;

      expect([supply.take(), supply.take(), supply.take()], ['1', '2', '3']);
      expect(supply.take(), isNull);
    });

    test('an older primary answering one number is still a reserve', () async {
      final supply = LanNumberSupply(ask: (_) async => ['7'])..prepare();
      await supply.settled;

      expect(supply.take(), '7');
      expect(supply.take(), isNull);
    });

    test('a primary that cannot be asked leaves nothing reserved', () async {
      final supply = LanNumberSupply(ask: (_) async => throw StateError('down'))..prepare();
      await supply.settled;

      expect(supply.take(), isNull);
    });

    test('is topped up only once half of it is used', () async {
      var asks = 0;
      final supply = LanNumberSupply(
          ask: (n) async {
            asks++;
            return counter(n);
          },
          batch: 4)
        ..prepare();
      await supply.settled;
      supply
        ..take()
        ..prepare();
      await supply.settled;
      expect(asks, 1, reason: 'three of four left');

      supply
        ..take()
        ..prepare();
      await supply.settled;
      expect(asks, 2);
      expect(supply.held, 4);
    });

    test('numbers held over a quiet spell are swapped for fresh ones', () async {
      var now = DateTime.utc(2026, 1, 1, 12);
      final supply = LanNumberSupply(ask: counter, batch: 2, now: () => now)..prepare();
      await supply.settled;

      now = now.add(supply.freshFor + const Duration(seconds: 1));
      expect(supply.held, 0);
      supply.prepare();
      await supply.settled;

      expect(supply.take(), '3');
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
