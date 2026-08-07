import 'database.dart';

/// The configured printers on disk, in the plain-map shape [PrinterRegistry] speaks.
///
/// The registry deliberately owns no storage, so this is the whole translation
/// layer: the row keys are the column names, which is why [load] and [save] are as
/// short as they are.
///
/// It lives in the database rather than in preferences for the same reason the
/// catalogue does. A till that cannot remember where the kitchen printer is has to
/// sweep the subnet on the first ticket of every shift.
class PrinterStore {
  PrinterStore(this._db);

  final Db _db;

  Map<String, Object?> load() => {
        'printers': [
          for (final r in _db.raw.select(
            'SELECT name, host, port, identity, last_seen_at FROM printers ORDER BY name',
          ))
            {
              'name': r['name'],
              'host': r['host'],
              'port': r['port'],
              'identity': r['identity'],
              'last_seen_at': r['last_seen_at'],
            },
        ],
      };

  /// Replaces the saved set, in one transaction. Called only when a stable fact
  /// changed, never on a plain confirmation, so this is not on the ticket path.
  void save(Map<String, Object?> data) {
    final rows = data['printers'];
    if (rows is! Iterable) return;
    _db.raw.execute('BEGIN');
    try {
      _db.raw.execute('DELETE FROM printers');
      for (final row in rows) {
        if (row is! Map) continue;
        _db.raw.execute(
          'INSERT INTO printers (name, host, port, identity, last_seen_at) VALUES (?,?,?,?,?)',
          [
            row['name'],
            row['host'],
            row['port'] ?? 9100,
            row['identity'],
            row['last_seen_at'],
          ],
        );
      }
      _db.raw.execute('COMMIT');
    } catch (_) {
      _db.raw.execute('ROLLBACK');
      rethrow;
    }
  }
}
