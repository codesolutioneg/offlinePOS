import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/sql_console.dart';

void main() {
  late Db db;
  late SqlConsole console;

  setUp(() {
    db = Db.open(':memory:');
    console = SqlConsole(db);
  });

  tearDown(() => db.raw.dispose());

  test('plain reads are reads', () {
    expect(console.isRead('SELECT * FROM audit_log'), isTrue);
    expect(console.isRead('WITH x AS (SELECT 1) SELECT * FROM x'), isTrue);
    expect(console.isRead('PRAGMA table_info(users)'), isTrue);
  });

  test('a write behind a WITH still needs the confirm', () {
    expect(
      console.isRead('WITH x AS (SELECT 1) DELETE FROM users WHERE 1 IN x'),
      isFalse,
    );
    expect(console.isRead('UPDATE users SET name = name'), isFalse);
  });

  test('a statement that does not compile is treated as a write', () {
    expect(console.isRead('SELEC nonsense'), isFalse);
  });

  test('a second statement is refused, not silently dropped', () {
    final r = console.run('SELECT 1; DELETE FROM users');
    expect(r.ok, isFalse);
  });

  test('the write result says it wrote', () {
    final r = console.run('UPDATE users SET name = name');
    expect(r.ok, isTrue);
    expect(r.readOnly, isFalse);
    expect(console.run('SELECT 1').readOnly, isTrue);
  });

  test('the key is out of reach with or without a schema prefix', () {
    for (final sql in [
      'PRAGMA key = "x"',
      'PRAGMA main.key = "x"',
      'PRAGMA main . rekey = "x"',
      'PRAGMA cipher_compatibility = 3',
      'PRAGMA cipher_version',
      'PRAGMA writable_schema = ON',
      "ATTACH DATABASE 'x.db' AS x",
      "VACUUM INTO 'x.db'",
    ]) {
      expect(console.run(sql).blocked, isTrue, reason: sql);
    }
  });

  test('the audit trail can be read but not changed', () {
    expect(console.run('SELECT * FROM audit_log').ok, isTrue);
    for (final sql in [
      'DELETE FROM audit_log',
      'WITH x AS (SELECT 1) DELETE FROM audit_log',
      'UPDATE audit_log SET action = action',
      'DROP TABLE audit_log',
    ]) {
      expect(console.run(sql).blocked, isTrue, reason: sql);
    }
  });

  test('the key stays out of reach however the pragma is spelled', () {
    for (final sql in [
      'PRAGMA "rekey" = \'x\'',
      'PRAGMA [rekey] = \'x\'',
      'PRAGMA `key` = \'x\'',
      'PRAGMA/**/rekey = \'x\'',
      'PRAGMA main."key" = \'x\'',
      '/* note */ PRAGMA cipher_compatibility = 3',
      "VACUUM main INTO 'x.db'",
    ]) {
      expect(console.run(sql).blocked, isTrue, reason: sql);
    }
  });

  test('a comment inside a string does not hide the audit trail', () {
    const sql = "CREATE TRIGGER t AFTER INSERT ON users WHEN '--' <> '' "
        'BEGIN DELETE FROM audit_log; END';
    expect(console.run(sql).blocked, isTrue);
  });

  test('a pragma that sets a value, or a transaction, is a write', () {
    for (final sql in [
      'PRAGMA foreign_keys = OFF',
      'PRAGMA main.foreign_keys = 0',
      'PRAGMA foreign_keys(0)',
      'BEGIN',
      'COMMIT',
      'SAVEPOINT a',
    ]) {
      expect(console.isRead(sql), isFalse, reason: sql);
    }
    expect(console.isRead('PRAGMA foreign_keys'), isTrue);
    expect(console.isRead('PRAGMA index_list("users")'), isTrue);
  });
}
