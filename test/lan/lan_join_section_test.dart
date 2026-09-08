import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/reservation_store.dart';
import 'package:offline_pos/core/db/schema.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/db/table_assignment_store.dart';
import 'package:offline_pos/core/db/table_store.dart';
import 'package:offline_pos/core/lan/lan_applier.dart';
import 'package:offline_pos/core/lan/lan_credential.dart';
import 'package:offline_pos/core/lan/lan_event.dart';
import 'package:offline_pos/core/lan/lan_event_log.dart';
import 'package:offline_pos/core/lan/lan_transport.dart';
import 'package:offline_pos/core/printing/printer_discovery.dart';
import 'package:offline_pos/core/printing/printer_registry.dart';
import 'package:offline_pos/domain/table_section_config.dart';

import '../db/sqlite_loader.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async =>
      const [];
}

void main() {
  setUpAll(useSystemSqlite);

  test('join endpoint returns shop key, section configs and printers for a valid PIN',
      () {
    final db = Db.open(':memory:');
    final settings = SettingsStore(db)
      ..deviceRole = DeviceRole.primary
      ..lanShopKey = 'shop-secret-key'
      ..setSectionConfig(const TableSectionConfig(
        name: 'officer',
        allowedCategoryIds: [4],
        allowedPaymentMethodIds: [1],
      ));
    final printers = PrinterRegistry(discovery: _NoPrinters())
      ..remember('kitchen', host: '192.168.1.50', port: 9100)
      ..remember('receipt', host: '192.168.1.51');
    final pin = settings.issueJoinPin()!;
    final log = LanEventLog(db, deviceId: 'primary');
    final applier = LanApplier(
      deviceId: 'primary',
      orders: OrderStore(db, ownDeviceId: 'primary'),
      tables: TableStore(db),
      settings: settings,
      reservations: ReservationStore(db),
      assignments: TableAssignmentStore(db),
      log: log,
    );
    final protocol = LanProtocol(
      deviceId: 'primary',
      log: log,
      applier: applier,
      credential: LanCredential('shop-secret-key'),
      onJoin: ({required pin, required peerDeviceId}) {
        if (!settings.isLanPrimary) return null;
        if (!settings.consumeJoinPin(pin)) return null;
        return {
          'shop_key': settings.lanShopKey,
          'section_configs': {
            for (final e in settings.allSectionConfigs().entries)
              e.key: e.value.toMap(),
          },
          'shop_bundle': settings.exportShopBundle(),
          'users': const <Map<String, dynamic>>[],
          'printers': printers.toMap(),
        };
      },
    );

    final reply = protocol.handlePost(
      LanProtocol.joinPath,
      jsonEncode({
        'device_id': 'secondary-1',
        'schema': Schema.version,
        'pin': pin,
      }),
    );
    expect(reply.status, 200);
    expect(reply.body['shop_key'], 'shop-secret-key');
    final configs = reply.body['section_configs'] as Map;
    expect(configs['officer']['allowed_category_ids'], [4]);
    expect(reply.body['shop_bundle'], isA<Map>());
    expect(reply.body['users'], isA<List>());
    final printersPayload = reply.body['printers'] as Map;
    final rows = printersPayload['printers'] as List;
    expect(rows, hasLength(2));
    expect(
      rows.map((r) => (r as Map)['name']),
      containsAll(['kitchen', 'receipt']),
    );

    final bad = protocol.handlePost(
      LanProtocol.joinPath,
      jsonEncode({
        'device_id': 'secondary-1',
        'schema': Schema.version,
        'pin': pin,
      }),
    );
    expect(bad.status, 403);
  });

  test('section config event applies on a peer', () {
    final a = Db.open(':memory:');
    final b = Db.open(':memory:');
    final settingsA = SettingsStore(a)..deviceRole = DeviceRole.primary;
    final settingsB = SettingsStore(b);
    final logA = LanEventLog(a, deviceId: 'a');
    final logB = LanEventLog(b, deviceId: 'b');
    final applierB = LanApplier(
      deviceId: 'b',
      orders: OrderStore(b, ownDeviceId: 'b'),
      tables: TableStore(b),
      settings: settingsB,
      reservations: ReservationStore(b),
      assignments: TableAssignmentStore(b),
      log: logB,
    );

    final cfg = const TableSectionConfig(
      name: 'e',
      isStaffSection: true,
      allowedCategoryIds: [9],
    );
    final event = logA.append(
      LanEventKind.sectionConfig,
      SettingsStore.sectionConfigRecord('e'),
      cfg.toMap(),
    );
    expect(applierB.applyAll('a', [event], highSeq: event.seq), 1);
    expect(settingsB.sectionConfig('e').allowedCategoryIds, [9]);
    expect(settingsB.sectionConfig('e').isStaffSection, isTrue);
    expect(settingsA, isNotNull);
  });
}
