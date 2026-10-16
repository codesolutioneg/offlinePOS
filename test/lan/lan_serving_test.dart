import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/auth/user_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/reservation_store.dart';
import 'package:offline_pos/core/db/schema.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/db/table_assignment_store.dart';
import 'package:offline_pos/core/db/table_store.dart';
import 'package:offline_pos/core/lan/lan_peer.dart';
import 'package:offline_pos/core/lan/lan_transport.dart';
import 'package:offline_pos/core/lan/lan_wiring.dart';
import 'package:offline_pos/core/printing/printer_discovery.dart';
import 'package:offline_pos/core/printing/printer_registry.dart';
import 'package:offline_pos/core/sync/odoo_endpoint.dart';
import 'package:offline_pos/domain/table_section_config.dart';

import '../db/sqlite_loader.dart';
import 'lan_wiring_test.dart' show FakeDatagramSocket;
import 'shop.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async =>
      const [];
}

/// A primary that could not open its server sent every secondary to local
/// numbering, and the two tills printed the same order numbers all day.
void main() {
  setUpAll(useSystemSqlite);

  group('the server', () {
    late TestShop shop;
    late TestTill till;
    setUp(() {
      shop = TestShop();
      till = shop.add('till-a');
    });
    tearDown(() => shop.close());

    test('binds every interface, so a stale first address cannot stop it', () async {
      final asked = <InternetAddress>[];
      final host = LanHost(
        protocol: till.protocol,
        port: 0,
        // What the primary listed: an address a disconnected adapter remembers,
        // ahead of the one it is really on.
        localAddresses: () async => ['192.168.0.20', '127.0.0.1'],
        bind: (address, port) {
          asked.add(address);
          return HttpServer.bind(InternetAddress.loopbackIPv4, port);
        },
      );
      addTearDown(host.stop);

      expect(await host.start(), isTrue);
      expect(asked.single, InternetAddress.anyIPv4);
      expect(host.hosts, ['192.168.0.20', '127.0.0.1']);
      expect(host.lastError, isNull);
    });

    test('says why when it cannot bind', () async {
      final host = LanHost(
        protocol: till.protocol,
        localAddresses: () async => ['127.0.0.1'],
        bind: (_, _) async => throw const SocketException('errno = 10049'),
      );

      expect(await host.start(), isFalse);
      expect(host.lastError, contains('10049'));
    });
  });

  group('the node', () {
    late Db db;
    setUp(() => db = Db.open(':memory:'));
    tearDown(() => db.close());

    test('keeps trying to serve, and announces it is not serving meanwhile', () async {
      var networkUp = false;
      final node = LanNode.build(
        db: db,
        deviceId: 'till-a',
        deviceName: 'Front',
        shopKey: () => 'the-shop-key',
        orders: OrderStore(db, ownDeviceId: 'till-a'),
        tables: TableStore(db),
        settings: SettingsStore(db),
        users: UserStore(db),
        printers: PrinterRegistry(discovery: _NoPrinters()),
        endpoints: OdooEndpointStore(db),
        reservations: ReservationStore(db),
        assignments: TableAssignmentStore(db),
        audit: AuditLog(db),
        port: 0,
        beaconPort: 0,
        localAddresses: () async => networkUp ? ['127.0.0.1'] : const [],
        beaconBind: (_, _) async => FakeDatagramSocket(),
        hostBind: (_, port) => HttpServer.bind(InternetAddress.loopbackIPv4, port),
        hostRetry: const Duration(milliseconds: 20),
      );
      addTearDown(node.dispose);

      await node.start();
      expect(node.isServing, isFalse);
      expect(node.facts.hostError, isNotNull);

      networkUp = true;
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!node.isServing && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(node.isServing, isTrue);
      expect(node.servingAt, startsWith('127.0.0.1:'));
      expect(node.facts.hostError, isNull);
    });
  });

  group('a peer that cannot serve', () {
    LanPeer heard(Map<String, dynamic> beacon) =>
        LanPeer.fromMap(beacon, host: '192.168.0.41', at: DateTime.utc(2026));

    final beacon = {
      'device_id': 'till-a',
      'name': 'Front',
      'port': 45333,
      'schema': Schema.version,
      'role': DeviceRole.primary.wire,
    };

    test('an older beacon without the flag is taken as serving', () {
      expect(heard(beacon).serving, isTrue);
      expect(heard(beacon).toMap().containsKey('serving'), isFalse);
    });

    test('is not counted as a reachable primary', () {
      final down = heard({...beacon, 'serving': false});

      expect(down.serving, isFalse);
      expect(down.seenAt(DateTime.utc(2026, 2)).serving, isFalse);
      expect(primaryReached(activePeers: [down], primaryDeviceId: 'till-a'), isFalse);
      expect(primaryReached(activePeers: [down], primaryDeviceId: null), isFalse);
      expect(primaryReached(activePeers: [heard(beacon)], primaryDeviceId: 'till-a'),
          isTrue);
    });
  });
}
