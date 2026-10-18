import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/schema.dart';
import 'package:offline_pos/core/lan/lan_credential.dart';
import 'package:offline_pos/core/lan/lan_peer.dart';
import 'package:offline_pos/core/lan/lan_transport.dart';
import 'package:offline_pos/domain/order.dart';

import '../db/sqlite_loader.dart';
import 'shop.dart';

void main() {
  setUpAll(useSystemSqlite);

  late TestShop shop;
  late TestTill till;
  setUp(() {
    shop = TestShop();
    till = shop.add('till-a', name: 'Front');
  });
  tearDown(() => shop.close());

  /// The two calls below go straight at the protocol rather than over a socket, so
  /// they carry the stamp the client would put on them. Pairing is asserted on its own
  /// in lan_pairing_test.dart; here it just has to be satisfied.
  LanReply pull(String path, Map<String, String> query) => till.protocol.handleGet(
        path,
        query,
        auth: till.credential.stamp(
            method: 'GET',
            path: path,
            query: LanCredential.canonicalQuery(query)),
      );

  LanReply push(String path, String body) => till.protocol.handlePost(
        path,
        body,
        auth: till.credential.stamp(method: 'POST', path: path, body: body),
      );

  test('an unknown path or method is answered, not crashed on', () {
    expect(pull('/anything', const {}).status, 404);
    expect(push('/anything', '{}').status, 404);
  });

  test('a notify with no device id or no events is refused', () {
    final schema = '${Schema.version}';
    expect(push(LanProtocol.notifyPath, '{"schema":$schema,"events":[]}').status, 400);
    expect(
        push(LanProtocol.notifyPath, '{"device_id":"b","schema":$schema}').status, 400);
    expect(push(LanProtocol.notifyPath, 'not json at all').status, 400);
  });

  test('one unreadable event does not spoil the page it arrived in', () {
    final other = shop.add('till-b');
    final order = heldOrder('till-b');
    other.orders.save(order);
    final good = other.log.since(0).single;

    final reply = push(LanProtocol.notifyPath,
        '{"device_id":"till-b","schema":${Schema.version},"events":['
        '{"kind":"order.invented","origin":"till-b","seq":99,"uuid":"x","payload":{},"at":"2026-01-01T09:00:00.000Z"},'
        '${jsonEncode(good.toMap())}]}');

    expect(reply.status, 200);
    expect(reply.body['applied'], 1);
    expect(till.orders.byUuid(order.uuid), isNotNull);
    expect(till.refusals.any((r) => r.startsWith('lan.event.refused')), isTrue);
    // The cursor cleared the event it could never read, so the page is not
    // fetched again forever.
    expect(till.log.cursorFor('till-b'), 99);
  });

  test('the high-water mark moves past events this build cannot serve', () {
    final reply =
        pull(LanProtocol.eventsPath, {'since': '0', 'schema': '${Schema.version}'});
    expect(reply.status, 200);
    expect(reply.body['events'], isEmpty);
    expect(reply.body['high_seq'], 0);
  });

  // The two tests below open a real loopback socket. They are given a wide timeout
  // on purpose: the suite runs many files at once and a starved isolate can take
  // seconds to be scheduled, which is not the socket failing.
  test('a peer pulls and pushes over a real socket', () async {
    final order = heldOrder('till-a');
    till.orders.save(order);

    // Bound on loopback with a port the machine picks, so the test cannot collide
    // with a real till on the same network.
    final host = LanHost(
      protocol: till.protocol,
      port: 0,
      localAddresses: () async => ['127.0.0.1'],
    );
    expect(await host.start(), isTrue);
    addTearDown(host.stop);

    final client = LanHttpClient(
        credential: till.credential, timeout: const Duration(seconds: 30));
    addTearDown(client.close);
    final self = LanPeer(
      deviceId: 'till-a',
      name: 'Front',
      host: host.host!,
      port: host.boundPort!,
      schemaVersion: Schema.version,
      lastSeenAt: DateTime.utc(2026),
    );

    final page = await client.fetch(self, 0);
    expect(page.events.single.recordUuid, order.uuid);
    expect(page.highSeq, page.events.single.seq);

    // And the same server accepts a push, which is how a till stays current
    // between pulls.
    final other = shop.add('till-b');
    final theirs = heldOrder('till-b', table: '9');
    other.orders.save(theirs);
    await client.notify(self, other.log.since(0), 'till-b');
    expect(till.orders.byUuid(theirs.uuid)!.tableLabel, '9');
    expect(till.orders.byUuid(theirs.uuid)!.state, OrderState.held);
  }, timeout: const Timeout(Duration(minutes: 2)));

  group('sales tally', () {
    final since = DateTime.utc(2026, 3, 1, 8);
    final until = DateTime.utc(2026, 3, 1, 23);

    Order rung(String device, DateTime at, {String? uuid}) {
      final o = Order(
        uuid: uuid,
        deviceId: device,
        cashierId: 'ana',
        createdAt: at,
      )..lines.add(OrderLine(productId: 1, name: 'Tea', quantity: 1, unitPrice: 10));
      o.payments = [OrderPayment(methodId: 1, amount: o.total, label: 'Cash')];
      o.state = OrderState.paid;
      return o;
    }

    test('a till answers the uuids of the sales it holds in the window', () async {
      final other = shop.add('till-b');
      final inside = rung('till-b', DateTime.utc(2026, 3, 1, 12));
      final replicated = rung('till-c', DateTime.utc(2026, 3, 1, 13));
      final before = rung('till-b', DateTime.utc(2026, 3, 1, 7));
      final after = rung('till-b', DateTime.utc(2026, 3, 2, 1));
      for (final o in [inside, replicated, before, after]) {
        other.orders.save(o, announce: false);
      }
      other.orders.save(heldOrder('till-b'), announce: false);

      final uuids = await shop.tally('till-a', shop.peerFor(other),
          since: since, until: until);
      // Any device's sales, held tabs and other days left out.
      expect(uuids, [inside.uuid, replicated.uuid]);
    });

    test('a till answers with its clock as it reads its sales', () async {
      final other = shop.add('till-b');
      final before = DateTime.now().toUtc().millisecondsSinceEpoch;
      final reply = await shop.tallyReply('till-a', shop.peerFor(other),
          since: since, until: until);
      final after = DateTime.now().toUtc().millisecondsSinceEpoch;
      expect(reply['clock'], inInclusiveRange(before, after));
    });

    test('a tally without the shop key is refused', () {
      final body = jsonEncode({
        'device_id': 'b',
        'schema': Schema.version,
        'since': since.toIso8601String(),
        'until': until.toIso8601String(),
      });
      expect(till.protocol.handlePost(LanProtocol.tallyPath, body).status, 401);
    });

    test('a tally without its window is refused', () {
      final body = jsonEncode({'device_id': 'b', 'schema': Schema.version});
      expect(push(LanProtocol.tallyPath, body).status, 400);
      final halfOpen = jsonEncode({
        'device_id': 'b',
        'schema': Schema.version,
        'since': since.toIso8601String(),
      });
      expect(push(LanProtocol.tallyPath, halfOpen).status, 400);
    });

    test('a till with no tally wired says so rather than answering empty', () async {
      // An empty list would read as "nothing rung here" and wave the close through.
      final older = shop.add('till-old', tallies: false);
      await expectLater(
        shop.tally('till-a', shop.peerFor(older), since: since, until: until),
        throwsA(isA<StateError>().having((e) => e.message, 'status',
            contains('409'))),
      );
    });

    test('the client reads a tally over a real socket', () async {
      final sale = rung('till-a', DateTime.utc(2026, 3, 1, 12));
      till.orders.save(sale, announce: false);
      final host = LanHost(
        protocol: till.protocol,
        port: 0,
        localAddresses: () async => ['127.0.0.1'],
      );
      expect(await host.start(), isTrue);
      addTearDown(host.stop);
      final client = LanHttpClient(
          credential: till.credential, timeout: const Duration(seconds: 30));
      addTearDown(client.close);
      final self = LanPeer(
        deviceId: 'till-a',
        name: 'Front',
        host: host.host!,
        port: host.boundPort!,
        schemaVersion: Schema.version,
        lastSeenAt: DateTime.utc(2026),
      );

      final before = DateTime.now().toUtc();
      final reply = await client.tally(self,
          deviceId: 'till-b', since: since, until: until);
      expect(reply.uuids, [sale.uuid]);
      expect(reply.clock!.isBefore(before), isFalse);
      // Both ends read the same clock here, so the offset is within the trip.
      expect(reply.clockOffset!.abs() < const Duration(seconds: 5), isTrue);
      expect(
          reply.clockOffset!.abs() <=
              reply.clockSpread + const Duration(milliseconds: 1),
          isTrue);

      final none = await client.tally(self,
          deviceId: 'till-b',
          since: DateTime.utc(2026, 3, 2),
          until: DateTime.utc(2026, 3, 3));
      expect(none.uuids, isEmpty);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  test('a request from another schema version is refused over the socket', () async {
    final host = LanHost(
      protocol: till.protocol,
      port: 0,
      localAddresses: () async => ['127.0.0.1'],
    );
    expect(await host.start(), isTrue);
    addTearDown(host.stop);

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
    addTearDown(() => client.close(force: true));
    final query = {'since': '0', 'schema': '${Schema.version + 1}'};
    final request = await client.getUrl(Uri.parse(
        'http://${host.host}:${host.boundPort}${LanProtocol.eventsPath}'
        '?since=0&schema=${Schema.version + 1}'));
    // Paired, so this reaches the schema gate rather than stopping at the pairing one.
    request.headers.set(
      LanCredential.header,
      till.credential.stamp(
          method: 'GET',
          path: LanProtocol.eventsPath,
          query: LanCredential.canonicalQuery(query)),
    );
    final response = await request.close();
    expect(response.statusCode, 409);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a till with no LAN address opens no socket at all', () async {
    final host = LanHost(
      protocol: till.protocol,
      localAddresses: () async => const [],
    );
    expect(await host.start(), isFalse);
    expect(host.isServing, isFalse);
  });
}
