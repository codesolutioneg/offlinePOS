import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/cloud/backup_envelope.dart';
import 'package:offline_pos/core/cloud/cloud_backup_service.dart';
import 'package:offline_pos/core/cloud/cloud_backup_state.dart';
import 'package:offline_pos/core/cloud/cloud_client.dart';
import 'package:offline_pos/core/cloud/cloud_secrets.dart';
import 'package:offline_pos/core/cloud/recovery_key.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/stress_purge.dart';
import 'package:sqlite3/sqlite3.dart';

import '../db/sqlite_loader.dart';

/// The backup server as the till sees it, in memory.
class FakeCloud {
  bool offline = false;
  String? keyId;
  final Map<String, String> tokens = {}; // token -> device id
  final List<({String id, String deviceId, String keyId, String reason, Uint8List body})>
      backups = [];

  Future<http.Response> handle(http.Request r) async {
    if (offline) throw const SocketException('no route to host');
    Map<String, String> json(Object body) => {'content-type': 'application/json'};
    http.Response reply(int status, Object body) =>
        http.Response(jsonEncode(body), status, headers: json(body));

    if (r.method == 'POST' && r.url.path == '/v1/devices/pair') {
      final m = jsonDecode(r.body) as Map<String, dynamic>;
      if (m['pair_code'] != 'SHOP-1') return reply(404, {'error': 'unknown pairing code'});
      final token = 'tok-${tokens.length + 1}';
      tokens[token] = m['device_id'] as String;
      return reply(200, {
        'token': token,
        'shop': {'name': 'Cairo branch', 'key_id': keyId},
      });
    }
    final token = (r.headers['authorization'] ?? '').replaceFirst('Bearer ', '');
    final device = tokens[token];
    if (device == null) return reply(401, {'error': 'device is not paired'});

    if (r.method == 'POST' && r.url.path == '/v1/backups') {
      final body = r.bodyBytes;
      if (crypto.sha256.convert(body).toString() != r.headers['x-backup-sha256']) {
        return reply(400, {'error': 'checksum mismatch'});
      }
      final k = r.headers['x-backup-key-id']!;
      keyId ??= k;
      if (k != keyId) return reply(409, {'error': 'this shop uses a different recovery key'});
      final id = 'b${backups.length + 1}';
      backups.add((
        id: id,
        deviceId: device,
        keyId: k,
        reason: r.headers['x-backup-reason'] ?? '',
        body: Uint8List.fromList(body),
      ));
      return reply(201, {'id': id});
    }
    if (r.method == 'GET' && r.url.path == '/v1/backups') {
      return reply(200, {
        'backups': [
          for (final b in backups.reversed)
            {
              'id': b.id,
              'device_id': b.deviceId,
              'device_name': '',
              'created_at': '2026-10-08T12:00:00Z',
              'size': b.body.length,
              'reason': b.reason,
              'key_id': b.keyId,
            }
        ],
      });
    }
    if (r.method == 'GET' && r.url.path.startsWith('/v1/backups/')) {
      final id = r.url.pathSegments.last;
      final b = backups.where((b) => b.id == id).firstOrNull;
      if (b == null) return reply(404, {'error': 'not found'});
      return http.Response.bytes(b.body, 200);
    }
    return reply(404, {'error': 'no such route'});
  }
}

void main() {
  late Directory dir;
  late Db db;
  late FakeCloud cloud;
  late DateTime clock;

  setUpAll(useSystemSqlite);
  setUp(() {
    dir = Directory.systemTemp.createTempSync('pos-cloud-test');
    db = Db.open('${dir.path}${Platform.pathSeparator}pos.db');
    cloud = FakeCloud();
    clock = DateTime(2026, 10, 8, 12);
  });
  tearDown(() {
    db.close();
    dir.deleteSync(recursive: true);
  });

  CloudBackupService service({
    CloudSecrets? secrets,
    String deviceId = 'till-1',
    Db? database,
    Duration tick = const Duration(minutes: 1),
    CloudBackupStateStore? state,
  }) =>
      CloudBackupService(
        db: database ?? db,
        state: state ?? MemoryCloudBackupStateStore(),
        secrets: secrets ?? MemoryCloudSecrets(),
        deviceId: deviceId,
        appVersion: '1.0.0',
        deviceName: () => 'Front counter',
        databaseKey: () async => 'db-key-1',
        clientFor: (url) => CloudClient(url, client: MockClient(cloud.handle)),
        scratch: () async => dir,
        audit: AuditLog(database ?? db),
        now: () => clock,
        tick: tick,
      );

  void sell(String uuid, {String note = ''}) => db.raw.execute(
        'INSERT INTO orders (uuid, device_id, cashier_id, created_at, state, total, payload) '
        "VALUES (?, 'till-1', 'sara', ?, 'paid', 10, ?)",
        [uuid, DateTime.now().toUtc().toIso8601String(), jsonEncode({'note': note})],
      );

  test('does nothing until the till is paired', () async {
    sell('sale-1');
    expect(await service().runNow(), CloudBackupOutcome.notConfigured);
    expect(cloud.backups, isEmpty);
  });

  test('pairing keeps the token in the keychain, not in the database', () async {
    final secrets = MemoryCloudSecrets();
    final s = service(secrets: secrets);
    expect(await s.pair(url: 'https://backup.test', pairCode: 'SHOP-1'), 'Cairo branch');

    expect(secrets.held[CloudBackupService.tokenSecret], 'tok-1');
    final settingsDump = db.raw.select('SELECT * FROM app_settings').toString();
    expect(settingsDump.contains('tok-1'), isFalse);
    expect((await s.status()).configured, isTrue);
  });

  test('a wrong pairing code is refused with the server\'s reason', () async {
    final s = service();
    await expectLater(s.pair(url: 'https://backup.test', pairCode: 'nope'),
        throwsA(isA<CloudError>().having((e) => e.message, 'message', 'unknown pairing code')));
    expect((await s.status()).configured, isFalse);
  });

  test('uploads the whole till, and it comes back as the same database', () async {
    sell('sale-1');
    sell('sale-2');
    final s = service();
    await s.pair(url: 'https://backup.test', pairCode: 'SHOP-1');

    expect(await s.runNow(), CloudBackupOutcome.uploaded);
    expect(cloud.backups, hasLength(1));
    expect(cloud.backups.single.keyId, (await s.recoveryKey()).id);

    final opened = await BackupEnvelope.open(cloud.backups.single.body, await s.recoveryKey());
    expect(opened.header.deviceId, 'till-1');
    expect(opened.header.dbKey, 'db-key-1');
    final restored = File('${dir.path}${Platform.pathSeparator}restored.db')
      ..writeAsBytesSync(opened.database);
    final copy = sqlite3.open(restored.path);
    addTearDown(copy.dispose);
    expect(copy.select('SELECT uuid FROM orders ORDER BY uuid').map((r) => r['uuid']),
        ['sale-1', 'sale-2']);
    // The snapshot taken for the upload is not left lying around.
    expect(dir.listSync().where((f) => f.path.contains('backup-')), isEmpty);
  });

  test('an unchanged till sends nothing the second time', () async {
    sell('sale-1');
    final s = service();
    await s.pair(url: 'https://backup.test', pairCode: 'SHOP-1');
    expect(await s.runNow(), CloudBackupOutcome.uploaded);
    expect(await s.runNow(), CloudBackupOutcome.unchanged);
    expect(cloud.backups, hasLength(1));

    sell('sale-2');
    expect(await s.runNow(), CloudBackupOutcome.uploaded);
    expect(cloud.backups, hasLength(2));
  });

  test('with no line it fails quietly, says why, and goes through later', () async {
    sell('sale-1');
    final s = service();
    await s.pair(url: 'https://backup.test', pairCode: 'SHOP-1');
    cloud.offline = true;

    expect(await s.runNow(), CloudBackupOutcome.failed);
    final down = await s.status();
    expect(down.lastError, contains('no route to host'));
    expect(down.lastSuccessAt, isNull);

    cloud.offline = false;
    expect(await s.runNow(), CloudBackupOutcome.uploaded);
    expect((await s.status()).lastError, isNull);
    expect((await s.status()).lastSuccessAt, clock);
  });

  test('a failure is audited once, not every retry of an outage', () async {
    final s = service();
    await s.pair(url: 'https://backup.test', pairCode: 'SHOP-1');
    cloud.offline = true;
    await s.runNow();
    await s.runNow();
    await s.runNow();
    final failures = db.raw
        .select("SELECT count(*) c FROM audit_log WHERE event = 'cloud.backup.failed'")
        .first['c'];
    expect(failures, 1);
  });

  test('Stress Lab orders never leave the till', () async {
    sell('lab-1', note: kStressNote);
    final s = service();
    await s.pair(url: 'https://backup.test', pairCode: 'SHOP-1');
    expect(await s.runNow(), CloudBackupOutcome.stressOrders);
    expect(cloud.backups, isEmpty);
  });

  test('shift close asks for a backup straight away', () async {
    sell('sale-1');
    final s = service();
    await s.pair(url: 'https://backup.test', pairCode: 'SHOP-1');
    s.request('shift-close');
    for (var i = 0; i < 100 && cloud.backups.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(cloud.backups.single.reason, 'shift-close');
  });

  test('the timer backs up once an hour, and waits after a failure', () async {
    sell('sale-1');
    final s = service(tick: const Duration(milliseconds: 10));
    await s.pair(url: 'https://backup.test', pairCode: 'SHOP-1');
    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 150));
    s.start();
    addTearDown(s.stop);

    await settle();
    expect(cloud.backups, hasLength(1), reason: 'never backed up, so due at once');

    sell('sale-2');
    clock = clock.add(const Duration(minutes: 30));
    await settle();
    expect(cloud.backups, hasLength(1), reason: 'not an hour yet');

    clock = clock.add(const Duration(minutes: 31));
    cloud.offline = true;
    await settle();
    expect((await s.status()).lastError, isNotNull);

    cloud.offline = false;
    clock = clock.add(const Duration(minutes: 2));
    await settle();
    expect(cloud.backups, hasLength(1), reason: 'still inside the retry wait');

    clock = clock.add(const Duration(minutes: 4));
    await settle();
    expect(cloud.backups, hasLength(2));
  });

  group('one recovery key per shop', () {
    late CloudBackupService first;

    setUp(() async {
      sell('sale-1');
      first = service();
      await first.pair(url: 'https://backup.test', pairCode: 'SHOP-1');
      await first.runNow();
    });

    test('a second till has to be given the shop\'s key', () async {
      final secrets = MemoryCloudSecrets();
      final second = service(secrets: secrets, deviceId: 'till-2');
      await expectLater(second.pair(url: 'https://backup.test', pairCode: 'SHOP-1'),
          throwsA(isA<RecoveryKeyNeeded>()));
      expect(secrets.held[CloudBackupService.tokenSecret], isNull);

      await expectLater(
          second.pair(
              url: 'https://backup.test',
              pairCode: 'SHOP-1',
              recoveryKey: RecoveryKey.generate().format()),
          throwsA(isA<RecoveryKeyMismatch>()));

      final key = (await first.recoveryKey()).format();
      await second.pair(url: 'https://backup.test', pairCode: 'SHOP-1', recoveryKey: key);
      expect(await second.runNow(), CloudBackupOutcome.uploaded);
      expect(cloud.backups.map((b) => b.keyId).toSet(), hasLength(1));
    });

    test('a till that sealed under another key is refused by the server', () async {
      final secrets = MemoryCloudSecrets()
        ..held[CloudBackupService.tokenSecret] = 'tok-1'
        ..held[CloudBackupService.recoveryKeySecret] = RecoveryKey.generate().format();
      final state = MemoryCloudBackupStateStore()
        ..state = CloudBackupState(url: 'https://backup.test');
      sell('sale-2');
      final rogue = service(secrets: secrets, state: state);
      expect(await rogue.runNow(), CloudBackupOutcome.failed);
      expect((await rogue.status()).lastError, contains('different recovery key'));
    });
  });

  test('the state file survives a restart', () async {
    final path = '${dir.path}${Platform.pathSeparator}cloud_backup.json';
    final secrets = MemoryCloudSecrets();
    sell('sale-1');
    final s = service(secrets: secrets, state: FileCloudBackupStateStore(path));
    await s.pair(url: 'https://backup.test', pairCode: 'SHOP-1');
    await s.runNow();

    final again = service(secrets: secrets, state: FileCloudBackupStateStore(path));
    final status = await again.status();
    expect(status.shopName, 'Cairo branch');
    expect(status.lastSuccessAt, clock);
    expect(await again.runNow(), CloudBackupOutcome.unchanged);
  });
}
