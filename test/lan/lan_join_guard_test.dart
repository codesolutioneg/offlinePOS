import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/reservation_store.dart';
import 'package:offline_pos/core/db/schema.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/db/table_assignment_store.dart';
import 'package:offline_pos/core/db/table_store.dart';
import 'package:offline_pos/core/lan/lan_applier.dart';
import 'package:offline_pos/domain/table_section_config.dart';
import 'package:offline_pos/core/lan/lan_credential.dart';
import 'package:offline_pos/core/lan/lan_event_log.dart';
import 'package:offline_pos/core/lan/lan_transport.dart';

import '../db/sqlite_loader.dart';

/// The join endpoint answers without the shop key, so it is held to the shop's
/// own network and to a handful of wrong PINs.
void main() {
  setUpAll(useSystemSqlite);

  late Db db;
  late SettingsStore settings;
  late DateTime now;
  late LanProtocol protocol;

  setUp(() {
    db = Db.open(':memory:');
    settings = SettingsStore(db)
      ..deviceRole = DeviceRole.primary
      ..lanShopKey = 'shop-secret-key';
    now = DateTime.utc(2026, 10, 9, 12);
    final log = LanEventLog(db, deviceId: 'primary');
    protocol = LanProtocol(
      deviceId: 'primary',
      log: log,
      applier: LanApplier(
        deviceId: 'primary',
        orders: OrderStore(db, ownDeviceId: 'primary'),
        tables: TableStore(db),
        settings: settings,
        reservations: ReservationStore(db),
        assignments: TableAssignmentStore(db),
        log: log,
      ),
      credential: LanCredential('shop-secret-key'),
      onJoin: ({required pin, required peerDeviceId}) =>
          settings.consumeJoinPin(pin)
          ? {'shop_key': settings.lanShopKey}
          : null,
      clock: () => now,
    );
  });
  tearDown(() => db.close());

  LanReply join(String pin, {String from = '192.168.1.20'}) =>
      protocol.handlePost(
        LanProtocol.joinPath,
        jsonEncode({'device_id': 'bar', 'pin': pin, 'schema': Schema.version}),
        remote: InternetAddress(from),
      );

  String wrong(String pin) => pin == '000000' ? '000001' : '000000';

  test('a good PIN from the shop network is admitted', () {
    final pin = settings.issueJoinPin()!;
    final r = join(pin);
    expect(r.status, 200);
    expect(r.body['shop_key'], 'shop-secret-key');
  });

  test('five wrong PINs lock the door, even to the right one', () {
    final pin = settings.issueJoinPin()!;
    for (var i = 0; i < LanProtocol.maxJoinFailures; i++) {
      expect(join(wrong(pin)).status, 403);
    }
    expect(join(pin).status, 429);
    expect(settings.joinPinBankCount, 1, reason: 'a locked door spends no PIN');
  });

  test('one device typing wrong PINs does not lock the others out', () {
    final pin = settings.issueJoinPin()!;
    for (var i = 0; i < LanProtocol.maxJoinFailures; i++) {
      join(wrong(pin), from: '192.168.1.66');
    }
    expect(join(pin, from: '192.168.1.66').status, 429);
    expect(join(pin).status, 200);
  });

  test('changing address does not buy more guesses than the network allows',
      () {
    final pin = settings.issueJoinPin()!;
    for (var i = 0; i < LanProtocol.maxShopJoinFailures; i++) {
      expect(join(wrong(pin), from: '192.168.1.${100 + i}').status, 403);
    }
    expect(join(pin, from: '192.168.1.200').status, 429);
  });

  test('the lock lifts after the lockout', () {
    final pin = settings.issueJoinPin()!;
    for (var i = 0; i < LanProtocol.maxJoinFailures; i++) {
      join(wrong(pin));
    }
    now = now.add(LanProtocol.joinLockout + const Duration(seconds: 1));
    expect(join(pin).status, 200);
  });

  test('wrong PINs spread out over time never lock', () {
    final pin = settings.issueJoinPin()!;
    for (var i = 0; i < LanProtocol.maxJoinFailures * 2; i++) {
      expect(join(wrong(pin)).status, 403);
      now = now.add(const Duration(minutes: 5));
    }
    expect(join(pin).status, 200);
  });

  test('a join from outside the shop network is refused', () {
    final pin = settings.issueJoinPin()!;
    expect(join(pin, from: '8.8.8.8').status, 403);
    expect(settings.joinPinBankCount, 1);
    expect(join(pin, from: '10.0.0.5').status, 200);
  });

  test('which addresses count as the shop network', () {
    for (final a in [
      '127.0.0.1',
      '10.1.2.3',
      '172.16.0.1',
      '172.31.255.1',
      '192.168.0.9',
      '169.254.1.1',
      '::1',
      'fd00::1',
      'fe80::1',
    ]) {
      expect(isLocalNetworkAddress(InternetAddress(a)), isTrue, reason: a);
    }
    for (final a in ['8.8.8.8', '172.32.0.1', '100.64.0.1', '2001:db8::1']) {
      expect(isLocalNetworkAddress(InternetAddress(a)), isFalse, reason: a);
    }
  });
}
