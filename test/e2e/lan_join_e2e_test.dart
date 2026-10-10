@Timeout(Duration(seconds: 90))
library;

import 'dart:convert';
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
import 'package:offline_pos/core/lan/lan_applier.dart';
import 'package:offline_pos/core/lan/lan_credential.dart';
import 'package:offline_pos/core/lan/lan_event_log.dart';
import 'package:offline_pos/core/lan/lan_peer.dart';
import 'package:offline_pos/core/lan/lan_transport.dart';
import 'package:offline_pos/core/lan/lan_wiring.dart';
import 'package:offline_pos/core/printing/printer_discovery.dart';
import 'package:offline_pos/core/printing/printer_registry.dart';
import 'package:offline_pos/core/sync/odoo_endpoint.dart';
import 'package:offline_pos/domain/table_section_config.dart' show DeviceRole;

import '../db/sqlite_loader.dart';
import '../lan/lan_wiring_test.dart' show FakeDatagramSocket;

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async =>
      const [];
}

/// One real till's LAN node: assembled by the same factory main.dart uses, its
/// HTTP server bound on loopback (port chosen by the OS), no beacon socket.
class _Till {
  _Till(String id, DeviceRole role) : deviceId = id {
    db = Db.open(':memory:');
    settings = SettingsStore(db)..deviceRole = role;
    audit = AuditLog(db);
    node = LanNode.build(
      db: db,
      deviceId: id,
      deviceName: id,
      shopKey: () => settings.lanShopKey ?? '',
      orders: OrderStore(db, ownDeviceId: id),
      tables: TableStore(db),
      settings: settings,
      users: UserStore(db),
      printers: PrinterRegistry(discovery: _NoPrinters()),
      endpoints: OdooEndpointStore(db),
      reservations: ReservationStore(db),
      assignments: TableAssignmentStore(db),
      audit: audit,
      port: 0,
      beaconPort: 0,
      localAddresses: () async => ['127.0.0.1'],
      beaconBind: (_, _) async => FakeDatagramSocket(),
      hostBind: (_, port) => HttpServer.bind(InternetAddress.loopbackIPv4, port),
    );
  }

  final String deviceId;
  late final Db db;
  late final SettingsStore settings;
  late final AuditLog audit;
  late final LanNode node;

  Future<void> up() async {
    await node.start();
    expect(node.isServing, isTrue, reason: 'the till must be serving on loopback');
  }

  LanPeer get asPeer {
    final port = int.parse(node.servingAt!.split(':').last);
    return LanPeer(
      deviceId: deviceId,
      name: deviceId,
      host: '127.0.0.1',
      port: port,
      schemaVersion: Schema.version,
      lastSeenAt: DateTime.now().toUtc(),
      role: DeviceRole.primary,
    );
  }

  Future<void> down() async {
    await node.dispose();
    db.close();
  }
}

/// Two tills on a shop LAN, over real sockets: a secondary joins the primary with
/// a one-time PIN, and the join door holds against guessing and outsiders.
void main() {
  setUpAll(useSystemSqlite);

  late _Till primary;
  late _Till secondary;

  setUp(() async {
    primary = _Till('primary-1', DeviceRole.primary);
    primary.settings.lanShopKey = LanCredential.newKey();
    secondary = _Till('secondary-1', DeviceRole.secondary);
    await primary.up();
  });
  tearDown(() async {
    await primary.down();
    await secondary.down();
  });

  /// The status code buried in the HttpException the client raises on non-200.
  Future<int?> joinStatus(String pin) async {
    try {
      await secondary.node.joinWithPrimary(primary.asPeer, pin);
      return 200;
    } on HttpException catch (e) {
      return int.tryParse(RegExp(r'^(\d{3}) from').firstMatch(e.message)?.group(1) ?? '');
    }
  }

  String wrong(String pin) => pin == '000000' ? '000001' : '000000';

  test('a secondary joins with a minted PIN over HTTP and receives the shop key',
      () async {
    final pin = primary.settings.issueJoinPin()!;
    expect(primary.settings.joinPinBankCount, 1);

    final reply = await secondary.node.joinWithPrimary(primary.asPeer, pin);

    expect(reply['shop_key'], primary.settings.lanShopKey);
    expect(reply['device_id'], 'primary-1');
    expect(reply['schema'], Schema.version);
    expect(primary.settings.joinPinBankCount, 0, reason: 'a PIN is single use');
    expect(primary.audit.recent(event: 'lan.device.joined'), isNotEmpty);
  });

  test('the key the secondary received is accepted by the primary on a stamped pull',
      () async {
    final pin = primary.settings.issueJoinPin()!;
    final reply = await secondary.node.joinWithPrimary(primary.asPeer, pin);
    final client = LanHttpClient(credential: LanCredential(reply['shop_key'] as String));
    addTearDown(client.close);

    final page = await client.fetch(primary.asPeer, 0);

    expect(page.highSeq, greaterThanOrEqualTo(0));
  });

  test('the same PIN cannot be used twice', () async {
    final pin = primary.settings.issueJoinPin()!;
    expect(await joinStatus(pin), 200);
    expect(await joinStatus(pin), 403);
  });

  test('five wrong PINs lock the door with 429, even to the right PIN', () async {
    final pin = primary.settings.issueJoinPin()!;
    for (var i = 0; i < LanProtocol.maxJoinFailures; i++) {
      expect(await joinStatus(wrong(pin)), 403, reason: 'wrong PIN #${i + 1}');
    }

    expect(await joinStatus(pin), 429);
    expect(await joinStatus(wrong(pin)), 429);
    expect(primary.settings.joinPinBankCount, 1,
        reason: 'a locked door must not spend the good PIN');
    expect(primary.audit.recent(event: 'lan.join.locked'), isNotEmpty);
  });

  test('a successful join clears the failure count', () async {
    final pin = primary.settings.issueJoinPin()!;
    final second = primary.settings.issueJoinPin()!;
    for (var i = 0; i < LanProtocol.maxJoinFailures - 1; i++) {
      expect(await joinStatus(wrong(pin)), 403);
    }
    expect(await joinStatus(pin), 200);
    // Four more would have been the ninth failure overall if the count survived.
    for (var i = 0; i < LanProtocol.maxJoinFailures - 1; i++) {
      expect(await joinStatus(wrong(second)), 403);
    }
    expect(await joinStatus(second), 200);
  });

  test('the lock lasts the documented fifteen minutes', () {
    expect(LanProtocol.joinLockout, const Duration(minutes: 15));
    expect(LanProtocol.maxJoinFailures, 5);
  });

  group('a request from outside the shop network', () {
    late LanProtocol protocol;
    late SettingsStore settings;
    setUp(() {
      // The same admission rule the node wires, on a protocol this test can call
      // with an address a loopback socket cannot spoof.
      settings = primary.settings;
      final log = LanEventLog(primary.db, deviceId: 'primary-1');
      protocol = LanProtocol(
        deviceId: 'primary-1',
        log: log,
        applier: LanApplier(
          deviceId: 'primary-1',
          orders: OrderStore(primary.db, ownDeviceId: 'primary-1'),
          tables: TableStore(primary.db),
          settings: settings,
          reservations: ReservationStore(primary.db),
          assignments: TableAssignmentStore(primary.db),
          log: log,
        ),
        credential: LanCredential(settings.lanShopKey!),
        onJoin: ({required pin, required peerDeviceId}) =>
            settings.consumeJoinPin(pin) ? {'shop_key': settings.lanShopKey} : null,
      );
    });

    LanReply join(String pin, String from) => protocol.handlePost(
          LanProtocol.joinPath,
          jsonEncode({'device_id': 'x', 'pin': pin, 'schema': Schema.version}),
          remote: InternetAddress(from),
        );

    test('is refused with 403 and the PIN is not spent', () {
      final pin = settings.issueJoinPin()!;

      final r = join(pin, '8.8.8.8');

      expect(r.status, 403);
      expect(r.body['error'], 'not on this network');
      expect(r.body.containsKey('shop_key'), isFalse);
      expect(settings.joinPinBankCount, 1);
      expect(join(pin, '192.168.1.40').status, 200);
    });

    test('guessing from outside never reaches the lock counter', () {
      final pin = settings.issueJoinPin()!;
      for (var i = 0; i < 10; i++) {
        expect(join(wrong(pin), '8.8.8.8').status, 403);
      }
      expect(join(pin, '10.0.0.7').status, 200,
          reason: 'outsiders must not be able to lock the shop out');
    });

    test('a bad device is locked by its own address while a good till still joins',
        () {
      final pin = settings.issueJoinPin()!;
      for (var i = 0; i < LanProtocol.maxJoinFailures; i++) {
        expect(join(wrong(pin), '192.168.1.99').status, 403);
      }

      expect(join(pin, '192.168.1.99').status, 429,
          reason: 'the guessing address is shut out, right PIN or not');
      expect(join(pin, '192.168.1.40').status, 200,
          reason: 'one noisy device must not lock the shop out of its own tills');
    });

    test('the shop-wide cap shuts every address once the network keeps guessing',
        () {
      final pin = settings.issueJoinPin()!;
      // Four wrong PINs from each of five addresses: no address reaches its own
      // limit of five, but together they reach the network's twenty.
      for (var host = 50; host < 55; host++) {
        for (var i = 0; i < LanProtocol.maxJoinFailures - 1; i++) {
          expect(join(wrong(pin), '192.168.1.$host').status, 403);
        }
      }

      expect(join(pin, '192.168.1.40').status, 429,
          reason: 'a fresh address is locked too once the cap is hit');
      expect(settings.joinPinBankCount, 1, reason: 'the good PIN was never spent');
      expect(LanProtocol.maxShopJoinFailures, 20);
    });
  });
}
