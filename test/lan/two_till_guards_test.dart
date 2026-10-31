import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/schema.dart';
import 'package:offline_pos/core/lan/lan_claim.dart';
import 'package:offline_pos/core/lan/lan_seat_desk.dart';
import 'package:offline_pos/core/lan/lan_transport.dart';
import 'package:offline_pos/domain/order.dart';

import '../db/sqlite_loader.dart';
import 'shop.dart';

/// Guards for the two-till findings (C1, C4, M1, M2) from
/// `docs/POS_TEST_INCIDENTS_VS_OFFLINEPOS.md`, on the same in-memory LAN the
/// replication tests use.
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

  group('M1 · one table per name, on every till', () {
    test('two tills that each added "10" apart settle on the same two names', () async {
      shop.unreachable.add('till-b');
      final ta = a.tables.add(name: '10');
      final tb = b.tables.add(name: '10');
      shop.unreachable.clear();

      await shop.settle();

      final keeper = ta.id.compareTo(tb.id) < 0 ? ta : tb;
      final other = keeper == ta ? tb : ta;
      for (final till in [a, b]) {
        expect(till.tables.byId(keeper.id)?.name, '10', reason: till.deviceId);
        expect(till.tables.byId(other.id)?.name, '10-${other.id.substring(0, 4)}',
            reason: till.deviceId);
        expect(till.tables.all().where((t) => t.name == '10'), hasLength(1));
      }
    });

    test('a till that already holds two "10"s upgrades, keeping the smaller id', () {
      a.db.raw.execute('DROP INDEX idx_pos_tables_name');
      for (final id in ['bbbb-2', 'aaaa-1']) {
        a.db.raw.execute(
            "INSERT INTO pos_tables (id, section, name, seats, pos_x, pos_y, sequence) "
            "VALUES (?, 'Main', '10', 4, 0, 0, 0)",
            [id]);
      }

      for (final stmt in Schema.migrations[27]) {
        a.db.raw.execute(stmt);
      }

      expect(a.tables.byId('aaaa-1')?.name, '10');
      expect(a.tables.byId('bbbb-2')?.name, '10-bbbb');
    });

    test('the database refuses a second table under a taken name', () {
      a.tables.add(name: '10');
      final dup = a.tables.add(name: '11');

      expect(() => a.tables.upsert(dup.copyWith(name: '10')), throwsA(anything));
    });
  });

  group('C4 · a tab changes hands only when it is safe', () {
    late Order tab;

    setUp(() async {
      tab = heldOrder('till-a');
      a.orders.save(tab);
      await shop.settle();
    });

    Future<Map<String, dynamic>> owner() async {
      final r = a.claims.grant(tab.uuid, 'till-b', asManager: true);
      return r.order?.toMap() ?? (throw LanTabRefused(r.detail ?? 'no'));
    }

    test('a silent owner is asked again, then needs a manager', () async {
      var asks = 0;
      final result = await b.claims.take(
        tab,
        ask: () async {
          asks++;
          throw StateError('no answer');
        },
        retryDelay: Duration.zero,
      );

      expect(asks, kClaimAttempts);
      expect(result.refusal, LanClaimRefusal.needsManager);
      expect(b.orders.byUuid(tab.uuid)?.deviceId, 'till-a');
    });

    test('an owner that answers on a retry hands the tab over, no seizure', () async {
      var asks = 0;
      final result = await b.claims.take(
        tab,
        ask: () {
          asks++;
          if (asks == 1) throw StateError('dropped');
          return owner();
        },
        retryDelay: Duration.zero,
      );

      expect(result.order?.deviceId, 'till-b');
      expect(b.audited.any((e) => e.startsWith('order.claim.seized')), isFalse);
    });

    test('a refusal is final and never retried', () async {
      var asks = 0;
      final result = await b.claims.take(
        tab,
        ask: () async {
          asks++;
          throw const LanTabRefused('not allowed');
        },
        asManager: true,
        retryDelay: Duration.zero,
      );

      expect(asks, 1);
      expect(result.refusal, LanClaimRefusal.refused);
      expect(b.orders.byUuid(tab.uuid)?.deviceId, 'till-a');
    });

    test('a manager seizure is marked, and the silent owner learns of it', () async {
      shop.unreachable.add('till-a');
      final result = await b.claims.take(
        tab,
        ask: () async => throw StateError('no answer'),
        asManager: true,
        retryDelay: Duration.zero,
      );
      expect(result.order?.deviceId, 'till-b');
      expect(b.audited.any((e) => e.startsWith('order.claim.seized')), isTrue);

      shop.unreachable.clear();
      await shop.settle();

      expect(a.orders.byUuid(tab.uuid)?.deviceId, 'till-b');
      expect(a.refusals.any((e) => e.startsWith('lan.order.seized')), isTrue);
    });

    test('the owner will not hand over the tab open on its screen', () async {
      a.settings.lanAllowTakeover = true;
      a.claims.isOnScreen = (uuid) => uuid == tab.uuid;

      expect(await shop.claim('till-b', a, tab.uuid), isNull);
      expect(a.orders.byUuid(tab.uuid)?.deviceId, 'till-a');

      a.claims.isOnScreen = null;
      expect(await shop.claim('till-b', a, tab.uuid), isNotNull);
    });
  });

  group('M2 · one table, one till', () {
    test('the primary refuses a table another till has just reserved', () {
      final desk = LanSeatDesk(orders: a.orders);

      expect(desk.reserve('7', 'till-b'), LanSeatAnswer.granted);
      expect(desk.reserve('7', 'till-c'), LanSeatAnswer.busy);
      expect(desk.reserve('7', 'till-b'), LanSeatAnswer.granted,
          reason: 'the same till asking again is not a clash');
    });

    test('a reservation lapses once replication has had time to carry the tab', () {
      var now = DateTime.utc(2026, 1, 1, 12);
      final desk = LanSeatDesk(orders: a.orders, now: () => now);

      desk.reserve('7', 'till-b');
      now = now.add(desk.holdFor + const Duration(seconds: 1));

      expect(desk.reserve('7', 'till-c'), LanSeatAnswer.granted);
    });

    test('the primary refuses a table its replica shows open on another till', () async {
      b.orders.save(heldOrder('till-b', table: '7'));
      await shop.settle();

      expect(LanSeatDesk(orders: a.orders).reserve('7', 'till-a'), LanSeatAnswer.busy);
    });

    test('the seat request is answered over the protocol by the primary only', () {
      final desk = LanSeatDesk(orders: a.orders);
      var primary = false;
      final protocol = LanProtocol(
        deviceId: 'till-a',
        log: a.log,
        applier: a.applier,
        credential: a.credential,
        seats: () => primary ? desk : null,
      );
      final body = jsonEncode({
        'device_id': 'till-b',
        'schema': Schema.version,
        'table': '7',
      });
      String? stamp() => b.credential
          .stamp(method: 'POST', path: LanProtocol.seatPath, body: body);

      expect(protocol.handlePost(LanProtocol.seatPath, body, auth: stamp()).status, 409);
      primary = true;
      final reply = protocol.handlePost(LanProtocol.seatPath, body, auth: stamp());
      expect(reply.status, 200);
      expect(reply.body['seat'], LanSeatAnswer.granted.name);
    });
  });

  group('C1 · the order-number floor', () {
    Order numbered(String device, String no,
        {OrderState state = OrderState.paid, DateTime? at, String? refundOf}) {
      final o = Order.fromMap({
        ...heldOrder(device).toMap(),
        'order_no': no,
        'state': state.name,
        'created_at': ?at?.toIso8601String(),
        'refund_of_uuid': ?refundOf,
      });
      a.orders.save(o, announce: false);
      return o;
    }

    test('an old open tab still counts, however many sales came after it', () {
      numbered('till-b', '50',
          state: OrderState.held, at: DateTime.utc(2026, 1, 1, 8));
      for (var i = 1; i <= 3; i++) {
        numbered('till-a', '$i', at: DateTime.utc(2026, 1, 1, 12, i));
      }

      expect(a.orders.orderNumberFloor(limit: 2), 50);
    });

    test('a refund or an unnumbered row does not move the floor', () {
      final sale = numbered('till-a', '7');
      numbered('till-a', '9999', refundOf: sale.uuid);
      a.orders.save(heldOrder('till-a'), announce: false);

      expect(a.orders.orderNumberFloor(), 7);
    });

    test('a number parked on the other till is climbed past here', () async {
      final tab = heldOrder('till-b')..orderNo = '41';
      b.orders.save(tab);
      await shop.settle();

      final next = a.settings
          .nextOrderNumber('till-a', atLeast: a.orders.orderNumberFloor());
      expect(int.parse(next), greaterThan(41));
    });
  });

  group('C4 · state only moves forward, whatever the clocks say', () {
    test('a sale paid on a slow-clocked till still lands as paid', () async {
      final slow = shop.add('till-slow', clock: StepClock(DateTime.utc(2026, 1, 1, 8)));
      shop.introduceAll();
      final tab = heldOrder('till-slow');
      slow.orders.save(tab);
      await shop.settle();

      // A later-stamped edit of the open tab from a till whose clock runs ahead.
      b.orders.save(Order.fromMap({...tab.toMap(), 'note': 'no onions'}));
      await shop.settle();

      slow.orders.save(Order.fromMap({
        ...slow.orders.byUuid(tab.uuid)!.toMap(),
        'state': OrderState.paid.name,
      }));
      await shop.settle();

      for (final till in [a, b]) {
        expect(till.orders.byUuid(tab.uuid)?.state, OrderState.paid,
            reason: till.deviceId);
      }
    });
  });
}
