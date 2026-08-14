import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/schema.dart';
import 'package:offline_pos/core/lan/lan_credential.dart';
import 'package:offline_pos/core/lan/lan_transport.dart';

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

  Map<String, String> pullQuery() =>
      {'since': '0', 'schema': '${Schema.version}'};

  /// A page of one real event, as a device on the LAN would have to send it to put an
  /// order on somebody else's till.
  String notifyBody() {
    final other = shop.add('till-b');
    final order = heldOrder('till-b');
    other.orders.save(order);
    return jsonEncode({
      'device_id': 'till-b',
      'schema': Schema.version,
      'events': [other.log.since(0).single.toMap()],
    });
  }

  test('a device with no shop key is told nothing and shown nothing', () {
    final reply = till.protocol.handleGet(LanProtocol.eventsPath, pullQuery());

    expect(reply.status, 401);
    // Not one event, and not even the till's schema version: an unpaired device
    // learns nothing about the shop from asking.
    expect(reply.body.containsKey('events'), isFalse);
    expect(reply.body['error'], LanAuth.missing.name);
    expect(till.refusals.any((r) => r.contains('no shop key at all')), isTrue);
  });

  test('a device paired to another shop cannot read the tabs', () {
    final guest = LanCredential('some-other-shops-key');

    final reply = till.protocol.handleGet(
      LanProtocol.eventsPath,
      pullQuery(),
      auth: guest.stamp(
          method: 'GET',
          path: LanProtocol.eventsPath,
          query: LanCredential.canonicalQuery(pullQuery())),
    );

    expect(reply.status, 401);
    expect(reply.body['error'], LanAuth.wrongKey.name);
    expect(till.refusals.any((r) => r.contains('another shop')), isTrue);
  });

  test('an unpaired device cannot push an order onto this till', () {
    final body = notifyBody();
    final uuid =
        ((jsonDecode(body) as Map)['events'] as List).single['uuid'] as String;

    final reply = till.protocol.handlePost(LanProtocol.notifyPath, body);

    expect(reply.status, 401);
    // The whole point: nothing was written, so a guest laptop cannot seed the floor
    // with orders nobody rang.
    expect(till.orders.byUuid(uuid), isNull);
  });

  test('a stamp lifted from a pull does not work on a push', () {
    // Signed over the request, not just the key, so capturing one read does not buy
    // the right to write.
    final lifted = till.credential.stamp(
        method: 'GET',
        path: LanProtocol.eventsPath,
        query: LanCredential.canonicalQuery(pullQuery()));

    final reply =
        till.protocol.handlePost(LanProtocol.notifyPath, notifyBody(), auth: lifted);

    expect(reply.status, 401);
    expect(reply.body['error'], LanAuth.wrongKey.name);
  });

  test('a stamp from a clock that drifted too far is named as a clock problem', () {
    final drifted = LanCredential(shop.shopKey,
        now: () => DateTime.now().toUtc().subtract(const Duration(minutes: 30)));

    final reply = till.protocol.handleGet(
      LanProtocol.eventsPath,
      pullQuery(),
      auth: drifted.stamp(
          method: 'GET',
          path: LanProtocol.eventsPath,
          query: LanCredential.canonicalQuery(pullQuery())),
    );

    expect(reply.status, 401);
    expect(reply.body['error'], LanAuth.staleClock.name);
    // Support has to be able to tell a wrong clock from a wrong key, because the two
    // look identical from the shop floor and have nothing to do with each other.
    expect(till.refusals.any((r) => r.contains('clocks is wrong')), isTrue);
  });

  test('a paired device is served, and the key itself never goes on the wire', () {
    final stamp = till.credential.stamp(
        method: 'GET',
        path: LanProtocol.eventsPath,
        query: LanCredential.canonicalQuery(pullQuery()));

    expect(
      till.protocol
          .handleGet(LanProtocol.eventsPath, pullQuery(), auth: stamp)
          .status,
      200,
    );
    expect(stamp.contains(shop.shopKey), isFalse);
  });

  test('a new key is long, random and url-safe', () {
    final first = LanCredential.newKey();
    final second = LanCredential.newKey();

    expect(first, isNot(second));
    // 32 bytes of entropy, and nothing in it that a settings field or a phone call
    // would mangle.
    expect(base64Url.decode(first).length, 32);
    expect(first, matches(RegExp(r'^[A-Za-z0-9_\-=]+$')));
  });
}
