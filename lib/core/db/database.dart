import 'package:sqlite3/sqlite3.dart';

import 'schema.dart';

/// Opens the local database and brings it up to [Schema.version].
///
/// The production build opens this through SQLCipher with a key from the platform
/// keystore; the migration logic is identical either way, which is what lets it be
/// tested against an in-memory database.
class Db {
  Db(this.raw);

  final Database raw;

  /// [path] of ':memory:' gives an ephemeral database, used by the tests.
  static Db open(String path, {String? encryptionKey}) {
    final db = sqlite3.open(path);
    if (encryptionKey != null && encryptionKey.isNotEmpty) {
      // Only effective against a SQLCipher-enabled build. Asserting the result
      // here would make the tests depend on SQLCipher being present.
      db.execute("PRAGMA key = '${encryptionKey.replaceAll("'", "''")}'");
    }
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA foreign_keys = ON');
    final instance = Db(db);
    instance.migrate();
    return instance;
  }

  int get userVersion =>
      raw.select('PRAGMA user_version').first.values.first! as int;

  /// Runs only the migrations this database has not seen, inside a transaction so a
  /// failure cannot leave a half-migrated till.
  void migrate() {
    var from = userVersion;
    if (from >= Schema.version) return;
    raw.execute('BEGIN');
    try {
      while (from < Schema.version) {
        for (final stmt in Schema.migrations[from]) {
          raw.execute(stmt);
        }
        from++;
      }
      raw.execute('PRAGMA user_version = $from');
      raw.execute('COMMIT');
    } catch (_) {
      raw.execute('ROLLBACK');
      rethrow;
    }
  }

  void close() => raw.dispose();
}
