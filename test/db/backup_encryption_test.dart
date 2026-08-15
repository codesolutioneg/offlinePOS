import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/export/db_backup.dart';

import 'sqlcipher_loader.dart';

/// A backup that quietly decrypted the till on its way out would be the worst kind
/// of feature: it looks like safety and it is a copy of every sale in plain text on
/// whatever stick it lands on.
void main() {
  // Same reason as encryption_test.dart: the system SQLCipher is only loaded on
  // Linux, and on Windows this harness would be testing the wrong library.
  if (!Platform.isLinux) return;
  setUpAll(useSystemSqlcipher);

  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('encbackup'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  final key = 'a' * 64;

  test('the copy is still encrypted, and still opens with the key', () async {
    final db = Db.open('${dir.path}${Platform.pathSeparator}pos.db',
        encryptionKey: key);
    db.raw.execute(
      "INSERT INTO orders (uuid, device_id, cashier_id, created_at, state, total, payload) "
      "VALUES ('u1','till-1','sara','2026-01-01T00:00:00Z','paid',1.0, ?)",
      ['CUSTOMER SECRET'],
    );

    final path = await backupDatabase(db, destination: () async => dir);
    db.close();

    // Nothing readable in the bytes: not the payload, not even the SQLite header.
    final bytes = File(path).readAsBytesSync();
    expect(String.fromCharCodes(bytes.take(16)), isNot(contains('SQLite')));
    expect(String.fromCharCodes(bytes), isNot(contains('CUSTOMER SECRET')));

    // And it is a real database to whoever holds the key.
    final restored = Db.open(path, encryptionKey: key);
    addTearDown(restored.close);
    expect(restored.raw.select('SELECT payload FROM orders').single['payload'],
        'CUSTOMER SECRET');
  });
}
