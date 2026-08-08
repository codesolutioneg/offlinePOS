import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/db_key.dart';

import 'sqlcipher_loader.dart';

class FakeKeyStore implements KeyStore {
  String? _v;
  @override Future<String?> read() async => _v;
  @override Future<void> write(String key) async => _v = key;
}

// Raw insert, no ON CONFLICT, so the proof does not depend on the upsert syntax the
// old system SQLCipher on the test box lacks (a device ships modern SQLCipher 4.x).
void _writeSecret(Db db, String secret) {
  db.raw.execute(
    "INSERT INTO orders (uuid, device_id, cashier_id, created_at, state, total, payload) "
    "VALUES ('u1','till-1','sara','2026-01-01T00:00:00Z','paid',1.0, ?)",
    [secret],
  );
}

void main() {
  // This proof loads the system libsqlcipher, which the loader only overrides on
  // Linux. On Windows the app uses the bundled SQLCipher via sqlcipher_flutter_libs;
  // running this harness there would test the wrong library and trips Windows file
  // locking on cleanup, so it is scoped to Linux.
  if (!Platform.isLinux) return;
  setUpAll(useSystemSqlcipher);

  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('encpos'));
  tearDown(() {
    // Best-effort: on Windows a DB file whose handle lingers cannot be deleted,
    // and a failed cleanup must not fail the test.
    try { dir.deleteSync(recursive: true); } catch (_) {}
  });
  String path() => '${dir.path}${Platform.pathSeparator}pos.db';

  test('a key generated once is reused the next time', () async {
    final store = FakeKeyStore();
    final k1 = await DbKey(store).getOrCreate();
    final k2 = await DbKey(store).getOrCreate();
    expect(k1, k2);
    expect(k1.length, 64);
  });

  test('data written with a key is not in the file as clear text', () async {
    final key = await DbKey(FakeKeyStore()).getOrCreate();
    final db = Db.open(path(), encryptionKey: key);
    _writeSecret(db, 'SecretPizza-ENC');
    db.close();

    final onDisk = String.fromCharCodes(File(path()).readAsBytesSync());
    expect(onDisk.contains('SecretPizza-ENC'), isFalse,
        reason: 'the payload is sitting in the file unencrypted');
  });

  test('the wrong key is rejected, not silently accepted', () async {
    final key = await DbKey(FakeKeyStore()).getOrCreate();
    final db = Db.open(path(), encryptionKey: key);
    _writeSecret(db, 'SecretPizza-ENC');
    db.close();

    expect(() => Db.open(path(), encryptionKey: 'f' * 64), throwsA(anything));

    final reopened = Db.open(path(), encryptionKey: key);
    final rows = reopened.raw.select("SELECT payload FROM orders WHERE uuid='u1'");
    expect(rows.single['payload'], 'SecretPizza-ENC');
    reopened.close();
  });

  test('control: with no key the same data IS in the file', () async {
    final db = Db.open(path());
    _writeSecret(db, 'PlainPizza-CLR');
    db.close();
    final onDisk = String.fromCharCodes(File(path()).readAsBytesSync());
    expect(onDisk.contains('PlainPizza-CLR'), isTrue);
  });
}
