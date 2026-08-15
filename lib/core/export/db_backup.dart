import 'dart:io';

import '../db/database.dart';
import 'data_export.dart';

/// A copy of the whole till, for the day the machine does not come back on.
///
/// Everything this shop has that the server has not seen yet lives in one file:
/// unsynced sales, the shift, the audit trail, the floor plan, the settings. A CSV
/// export is for reading; this is for restoring, and it is the only thing that turns
/// a dead till into a replaced one.
///
/// The copy stays exactly as encrypted as the original, because it IS the original's
/// bytes. Nothing is decrypted, re-keyed or re-written on the way out, so a backup on
/// a memory stick is worth nothing to whoever finds it without the device's key. That
/// also means a restore needs the key from the same keychain: see docs/SECURITY.md.
class DatabaseHasNoFile implements Exception {
  const DatabaseHasNoFile();
  @override
  String toString() => 'DatabaseHasNoFile: this database is in memory';
}

/// The file the main database lives in, or null when it is in memory (the tests).
///
/// Asked of SQLite rather than threaded down from wherever the path was chosen, so
/// the backup cannot end up copying a file the app is not actually using.
String? databaseFile(Db db) {
  for (final row in db.raw.select('PRAGMA database_list')) {
    if (row['name'] == 'main') {
      final file = row['file'];
      if (file is String && file.isNotEmpty) return file;
    }
  }
  return null;
}

/// Writes a copy of the database next to the other exports and returns its path.
///
/// Never blocks the till: the checkpoint is a fast local call and the copy itself is
/// asynchronous file IO, so a sale rung while this runs is unaffected. A sale rung
/// DURING the copy is not in the backup, which is the honest meaning of a snapshot.
///
/// [at] stamps the file name; [destination] is for tests, which have no platform
/// directories.
Future<String> backupDatabase(
  Db db, {
  DateTime? at,
  Future<Directory> Function()? destination,
}) async {
  final source = databaseFile(db);
  if (source == null) throw const DatabaseHasNoFile();

  // Fold the write-ahead log into the main file, so what gets copied is a whole
  // database and not one that is missing today's sales.
  //
  // Then stop the automatic checkpoint for the length of the copy. In WAL mode a
  // write lands in the log, not in the file being copied, EXCEPT when a checkpoint
  // fires part way through and starts rewriting pages underneath it. That would
  // produce a torn file that looks like a backup and is not one.
  db.raw.execute('PRAGMA wal_autocheckpoint = 0');
  try {
    db.raw.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    final dir = destination == null ? await exportDirectory() : await destination();
    final path =
        '${dir.path}${Platform.pathSeparator}${exportFileName('backup', at ?? DateTime.now(), 'db')}';
    await File(source).copy(path);
    return path;
  } finally {
    // SQLite's own default, restored whatever happened, so a failed backup cannot
    // leave the till growing a log forever.
    db.raw.execute('PRAGMA wal_autocheckpoint = 1000');
  }
}
