import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/cloud/backup_envelope.dart';
import 'package:offline_pos/core/cloud/cloud_backup_service.dart';
import 'package:offline_pos/core/cloud/cloud_backup_state.dart';
import 'package:offline_pos/core/cloud/cloud_secrets.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:sqlite3/sqlite3.dart';

import '../db/sqlite_loader.dart';

/// Against a real backup server, only when one is named:
///   flutter test test/cloud/live_server_test.dart
///     --dart-define=CLOUD_E2E_URL=https://… --dart-define=CLOUD_E2E_CODE=XXXX-…
/// Use a throwaway shop: the first upload fixes the shop's recovery key.
const _url = String.fromEnvironment('CLOUD_E2E_URL');
const _code = String.fromEnvironment('CLOUD_E2E_CODE');

void main() {
  setUpAll(useSystemSqlite);

  test('a till backs up to the live server and the backup comes back whole', () async {
    final dir = Directory.systemTemp.createTempSync('pos-cloud-live');
    final db = Db.open('${dir.path}${Platform.pathSeparator}pos.db');
    addTearDown(() {
      db.close();
      dir.deleteSync(recursive: true);
    });
    db.raw.execute(
      'INSERT INTO orders (uuid, device_id, cashier_id, created_at, state, total, payload) '
      "VALUES ('live-sale-1', 'live-till', 'sara', ?, 'paid', 42, '{}')",
      [DateTime.now().toUtc().toIso8601String()],
    );

    final service = CloudBackupService(
      db: db,
      state: MemoryCloudBackupStateStore(),
      secrets: MemoryCloudSecrets(),
      deviceId: 'live-till-${DateTime.now().millisecondsSinceEpoch}',
      appVersion: 'e2e',
      deviceName: () => 'E2E till',
      databaseKey: () async => 'e2e-db-key',
      scratch: () async => dir,
    );

    final shop = await service.pair(url: _url, pairCode: _code);
    expect(shop, isNotEmpty);
    expect(await service.runNow(reason: 'e2e'), CloudBackupOutcome.uploaded,
        reason: (await service.status()).lastError);
    expect(await service.runNow(reason: 'e2e'), CloudBackupOutcome.unchanged);

    final (:client, :token) = (await service.connection())!;
    addTearDown(client.close);
    final listed = await client.list(token);
    final mine = listed.firstWhere((b) => b.deviceName == 'E2E till');
    expect(mine.reason, 'e2e');
    expect(mine.keyId, (await service.recoveryKey()).id);

    final sealed = await client.download(token, mine.id);
    final opened = await BackupEnvelope.open(sealed, await service.recoveryKey());
    expect(opened.header.dbKey, 'e2e-db-key');
    final copyPath = '${dir.path}${Platform.pathSeparator}from-server.db';
    File(copyPath).writeAsBytesSync(opened.database);
    final copy = sqlite3.open(copyPath);
    addTearDown(copy.dispose);
    expect(copy.select('SELECT uuid, total FROM orders').single['uuid'], 'live-sale-1');
  }, skip: _url.isEmpty || _code.isEmpty ? 'no live server named' : false);
}
