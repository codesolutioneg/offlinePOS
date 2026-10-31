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
import 'package:offline_pos/core/lan/lan_credential.dart';
import 'package:offline_pos/core/lan/lan_peer.dart';
import 'package:offline_pos/core/lan/lan_transport.dart';
import 'package:offline_pos/core/lan/lan_wiring.dart';
import 'package:offline_pos/core/printing/printer_discovery.dart';
import 'package:offline_pos/core/printing/printer_registry.dart';
import 'package:offline_pos/core/sync/odoo_endpoint.dart';
import 'package:offline_pos/domain/table_section_config.dart';

import '../db/sqlite_loader.dart';
import 'lan_wiring_test.dart' show FakeDatagramSocket;

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async =>
      const [];
}

/// A primary that hands out numbers from 100 up, without a network.
class _Primary extends LanHttpClient {
  _Primary() : super(credential: LanCredential('the-shop-key'));

  var next = 100;
  var asks = 0;

  @override
  Future<LanPage> fetch(LanPeer peer, int since) async => LanPage.empty;

  @override
  Future<List<String>> numbers(LanPeer peer, {required String deviceId, int count = 1}) async {
    asks++;
    return [for (var i = 0; i < count; i++) '${next++}'];
  }
}

/// The first sales on the secondary at 17:50 were paid 150 ms after the run
/// started, before the first reserve had come back, and took tagged numbers.
void main() {
  setUpAll(useSystemSqlite);

  late Db db;
  late SettingsStore settings;
  late _Primary primary;
  late LanNode node;

  setUp(() {
    db = Db.open(':memory:');
    settings = SettingsStore(db)
      ..deviceRole = DeviceRole.secondary
      ..lanPrimaryDeviceId = 'till-a';
    primary = _Primary();
    node = LanNode.build(
      db: db,
      deviceId: 'till-b',
      deviceName: 'Back',
      shopKey: () => 'the-shop-key',
      orders: OrderStore(db, ownDeviceId: 'till-b'),
      tables: TableStore(db),
      settings: settings,
      users: UserStore(db),
      printers: PrinterRegistry(discovery: _NoPrinters()),
      endpoints: OdooEndpointStore(db),
      reservations: ReservationStore(db),
      assignments: TableAssignmentStore(db),
      audit: AuditLog(db),
      port: 0,
      beaconPort: 0,
      localAddresses: () async => const [],
      beaconBind: (_, _) async => FakeDatagramSocket(),
      client: primary,
    );
    node.peers.seen(LanPeer(
      deviceId: 'till-a',
      name: 'Front',
      host: '127.0.0.1',
      port: 45333,
      schemaVersion: Schema.version,
      lastSeenAt: DateTime.now().toUtc(),
      role: DeviceRole.primary,
    ));
  });
  tearDown(() async {
    await node.dispose();
    db.close();
  });

  test('a secondary reserves numbers as soon as it joins the LAN', () async {
    await node.start();
    await node.readyToNumber();

    expect(primary.asks, 1);
    expect(node.takeOrderNumber(), '100');
  });

  test('a sale paid straight after start-up gets a number off the primary', () async {
    await node.start();
    await node.readyToNumber();

    final burst = [node.takeOrderNumber(), node.takeOrderNumber(), node.takeOrderNumber()];
    expect(burst, ['100', '101', '102']);
    expect(node.numbersBelongToPrimary, isTrue);
  });
}
