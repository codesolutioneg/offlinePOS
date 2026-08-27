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
    // Before anything reads the file, because the key check below is itself a read
    // and is the first thing a lock left by another connection can hit. At the
    // default of zero that read fails outright, which on a till reads as an app
    // that will not open. Sets a connection option only; it touches no page, so it
    // does not disturb the key having to come before the first read.
    db.execute('PRAGMA busy_timeout = 5000');
    if (encryptionKey != null && encryptionKey.isNotEmpty) {
      // Must be the first statement to touch the file: SQLCipher decrypts lazily on
      // the first read, so the key has to be set before journal_mode touches it.
      // A 64-char hex value is a raw 32-byte key (x'..'), used directly with no
      // key-derivation step; anything else is treated as a passphrase.
      final isRawHex =
          encryptionKey.length == 64 && RegExp(r'^[0-9a-fA-F]+$').hasMatch(encryptionKey);
      if (isRawHex) {
        db.execute("PRAGMA key = \"x'$encryptionKey'\"");
      } else {
        final escaped = encryptionKey.replaceAll("'", "''");
        db.execute("PRAGMA key = '$escaped'");
      }
      // Prove the key is right before migrating. On a wrong key SQLCipher cannot
      // read the schema and this throws, which is far better than a later, vaguer
      // failure deep in a query.
      db.execute('SELECT count(*) FROM sqlite_master');
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
