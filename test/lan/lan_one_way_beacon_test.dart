import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/schema.dart';
import 'package:offline_pos/core/lan/lan_credential.dart';
import 'package:offline_pos/core/lan/lan_peer.dart';
import 'package:offline_pos/core/lan/lan_transport.dart';
import 'package:offline_pos/domain/table_section_config.dart';

import '../db/sqlite_loader.dart';
import 'shop.dart';

/// A till on two adapters can hear the others' beacons while its own never reaches
/// them. Its signed pulls and pushes still do, and are enough for the others to
/// read it back; otherwise a table it seats is busy on it and free everywhere else.
void main() {
  setUpAll(useSystemSqlite);

  late TestShop shop;
  late TestTill server;
  setUp(() {
    shop = TestShop();
    server = shop.add('server', name: 'Server');
  });
  tearDown(() => shop.close());

  Map<String, String> pullQuery({String? peer, String? port}) => {
        'since': '0',
        'schema': '${Schema.version}',
        'peer': ?peer,
        'port': ?port,
      };

  LanReply pull(Map<String, String> query, {String? from, bool signed = true}) =>
      server.protocol.handleGet(
        LanProtocol.eventsPath,
        query,
        auth: signed
            ? server.credential.stamp(
                method: 'GET',
                path: LanProtocol.eventsPath,
                query: LanCredential.canonicalQuery(query))
            : null,
        from: from,
      );

  test('a signed pull from a till never heard on the beacon makes it a peer', () {
    expect(server.peers.active, isEmpty);

    final reply =
        pull(pullQuery(peer: 'till-a', port: '45333'), from: '192.168.8.131');

    expect(reply.status, 200);
    final peer = server.peers.active.single;
    expect(peer.deviceId, 'till-a');
    expect(peer.host, '192.168.8.131');
    expect(peer.port, 45333);
  });

  test('a signed notify makes its sender a peer too', () {
    final body = jsonEncode({
      'device_id': 'till-a',
      'schema': Schema.version,
      'port': 45333,
      'events': const [],
    });
    server.protocol.handlePost(
      LanProtocol.notifyPath,
      body,
      auth: server.credential
          .stamp(method: 'POST', path: LanProtocol.notifyPath, body: body),
      from: '192.168.8.131',
    );

    expect(server.peers.active.single.deviceId, 'till-a');
  });

  test('an unsigned pull is refused and teaches the till nothing', () {
    final reply = pull(pullQuery(peer: 'intruder', port: '45333'),
        from: '192.168.8.66', signed: false);

    expect(reply.status, 401);
    expect(server.peers.all, isEmpty);
  });

  test('an older build that does not say who it is is left to its beacon', () {
    pull(pullQuery(), from: '192.168.8.131');
    expect(server.peers.all, isEmpty);
  });

  test('a peer known from its beacon keeps its name and address', () {
    server.peers.seen(LanPeer(
      deviceId: 'till-a',
      name: 'Front',
      host: '192.168.8.131',
      port: 45333,
      schemaVersion: Schema.version,
      lastSeenAt: DateTime.now().toUtc(),
      role: DeviceRole.secondary,
    ));

    pull(pullQuery(peer: 'till-a', port: '45333'), from: '192.168.1.65');

    final peer = server.peers.active.single;
    expect(peer.name, 'Front');
    expect(peer.host, '192.168.8.131');
    expect(peer.role, DeviceRole.secondary);
  });
}
