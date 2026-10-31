import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/cloud/cloud_secrets.dart';
import 'package:offline_pos/core/cloud/pending_restore.dart';
import 'package:offline_pos/core/db/db_key.dart';

class _Keys implements KeyStore {
  _Keys(this.key);
  String? key;

  @override
  Future<String?> read() async => key;

  @override
  Future<void> write(String key) async => this.key = key;
}

void main() {
  late Directory dir;
  late String dbPath;
  late MemoryCloudSecrets secrets;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pos-restore-test');
    dbPath = '${dir.path}${Platform.pathSeparator}pos.db';
    secrets = MemoryCloudSecrets();
    File(dbPath).writeAsStringSync('old database');
    File('$dbPath-wal').writeAsStringSync('old log');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  final restored = Uint8List.fromList('restored database'.codeUnits);

  test('nothing staged, nothing touched', () async {
    final keys = _Keys('old-key');
    expect(await PendingRestore(dbPath, secrets).apply(keys), isNull);
    expect(File(dbPath).readAsStringSync(), 'old database');
    expect(keys.key, 'old-key');
  });

  test('the staged database takes over at launch, and the old one is kept', () async {
    final keys = _Keys('old-key');
    final restore = PendingRestore(dbPath, secrets);
    await restore.stage(restored, databaseKey: 'restored-key');
    expect(restore.isStaged, isTrue);
    // Staging alone changes nothing the running till is using.
    expect(File(dbPath).readAsStringSync(), 'old database');
    expect(keys.key, 'old-key');

    final kept = await restore.apply(keys, at: DateTime(2026, 10, 8, 14, 5));

    expect(File(dbPath).readAsBytesSync(), restored);
    expect(File('$dbPath-wal').existsSync(), isFalse,
        reason: 'the old log must not be replayed into the restored database');
    expect(File(kept!).readAsStringSync(), 'old database');
    expect(File('$kept-wal').readAsStringSync(), 'old log');
    expect(keys.key, 'restored-key');
    expect(secrets.held[PendingRestore.previousKeySecret], 'old-key');
    expect(secrets.held[PendingRestore.restoreKeySecret], isNull);
    expect(restore.isStaged, isFalse);
  });

  test('a backup that carried no key leaves the till\'s key alone', () async {
    final keys = _Keys('old-key');
    final restore = PendingRestore(dbPath, secrets);
    await restore.stage(restored);
    await restore.apply(keys);
    expect(keys.key, 'old-key');
    expect(File(dbPath).readAsBytesSync(), restored);
  });

  test('a cancelled restore never happens', () async {
    final keys = _Keys('old-key');
    final restore = PendingRestore(dbPath, secrets);
    await restore.stage(restored, databaseKey: 'restored-key');
    await restore.cancel();
    expect(await restore.apply(keys), isNull);
    expect(File(dbPath).readAsStringSync(), 'old database');
    expect(keys.key, 'old-key');
  });
}
