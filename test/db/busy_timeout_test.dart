import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/db_key.dart';

import 'sqlcipher_loader.dart';
import 'sqlite_loader.dart';

class FakeKeyStore implements KeyStore {
  String? _v;
  @override
  Future<String?> read() async => _v;
  @override
  Future<void> write(String key) async => _v = key;
}

void main() {
  group('plain', () {
    setUpAll(useSystemSqlite);

    test('a moment of contention is waited out rather than fatal', () {
      final db = Db.open(':memory:');

      expect(
        db.raw.select('PRAGMA busy_timeout').first.values.first,
        5000,
        reason: 'at the default of zero, another connection still letting go of '
            'the file makes a launch fail outright',
      );
      db.close();
    });
  });

  group('encrypted', () {
    // Scoped to Linux for the same reason as encryption_test: this harness loads
    // the system libsqlcipher, and on Windows the app uses the bundled one.
    if (!Platform.isLinux) return;
    setUpAll(useSystemSqlcipher);

    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('busypos'));
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('the timeout is already in force for the key check', () async {
      // The production path: the first read of the file is the key verification
      // inside Db.open, so a timeout set after it would not cover the launch it
      // is meant to protect.
      final key = await DbKey(FakeKeyStore()).getOrCreate();
      final path = '${dir.path}${Platform.pathSeparator}pos.db';

      final db = Db.open(path, encryptionKey: key);

      expect(db.raw.select('PRAGMA busy_timeout').first.values.first, 5000);
      db.close();
    });
  });
}
