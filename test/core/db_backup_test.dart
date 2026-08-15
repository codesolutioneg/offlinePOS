import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/export/db_backup.dart';
import 'package:sqlite3/sqlite3.dart';

import '../db/sqlite_loader.dart';

/// The copy has to be a database that opens, taken without stopping the till, and
/// the till has to be fine afterwards. A backup that is only a file of the right
/// size is worse than none, because a shop will believe in it.
void main() {
  late Directory dir;
  late Db db;

  setUpAll(useSystemSqlite);
  setUp(() {
    dir = Directory.systemTemp.createTempSync('pos-backup-test');
    db = Db.open('${dir.path}${Platform.pathSeparator}pos.db');
  });
  tearDown(() {
    db.close();
    dir.deleteSync(recursive: true);
  });

  Future<Directory> here() async => dir;

  void sell(String uuid) => db.raw.execute(
        'INSERT INTO orders (uuid, device_id, cashier_id, created_at, state, total, payload) '
        "VALUES (?, 'till-1', 'sara', ?, 'paid', 10, '{}')",
        [uuid, DateTime.now().toUtc().toIso8601String()],
      );

  test('the copy opens as a database and holds the sales', () async {
    sell('sale-1');
    sell('sale-2');

    final path = await backupDatabase(db,
        at: DateTime(2026, 8, 15, 9, 30), destination: here);

    expect(path, endsWith('backup-20260815-0930.db'));
    expect(File(path).existsSync(), isTrue);

    final copy = sqlite3.open(path);
    addTearDown(copy.dispose);
    expect(copy.select('SELECT uuid FROM orders ORDER BY uuid').map((r) => r['uuid']),
        ['sale-1', 'sale-2']);
  });

  test('the till keeps working, before and after', () async {
    sell('sale-1');
    await backupDatabase(db, destination: here);

    // The sale that comes in after the snapshot is not in it, and the database it
    // was taken from is untouched.
    sell('sale-2');
    expect(db.raw.select('SELECT count(*) c FROM orders').first['c'], 2);
  });

  test('the automatic checkpoint is put back however the copy went', () async {
    await backupDatabase(db, destination: here);
    expect(db.raw.select('PRAGMA wal_autocheckpoint').first.values.first, 1000);

    // A destination that cannot be written to: the copy throws and the setting is
    // still restored.
    await expectLater(
        backupDatabase(db,
            destination: () async => Directory('/definitely/not/a/directory')),
        throwsA(isA<FileSystemException>()));
    expect(db.raw.select('PRAGMA wal_autocheckpoint').first.values.first, 1000);
  });

  test('an in-memory database says it has no file rather than writing an empty one',
      () async {
    final memory = Db.open(':memory:');
    addTearDown(memory.close);

    expect(databaseFile(memory), isNull);
    await expectLater(backupDatabase(memory, destination: here),
        throwsA(isA<DatabaseHasNoFile>()));
  });

  test('the file on disk is the one that gets copied', () {
    expect(databaseFile(db), endsWith('pos.db'));
  });
}
