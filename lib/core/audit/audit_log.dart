import '../db/database.dart';

/// Append-only record of who did what on this till.
///
/// Written locally first so an action taken during an outage is still accountable;
/// synced later like everything else.
class AuditLog {
  AuditLog(this._db, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final Db _db;
  final DateTime Function() _now;

  void record(String actor, String event, {String? detail}) {
    _db.raw.execute(
      'INSERT INTO audit_log (at, actor, event, detail) VALUES (?,?,?,?)',
      [_now().toUtc().toIso8601String(), actor, event, detail],
    );
  }

  /// Entries the server has not seen, oldest first.
  List<Map<String, Object?>> unsynced({int limit = 200}) => _db.raw
      .select('SELECT * FROM audit_log WHERE synced_at IS NULL ORDER BY id LIMIT ?', [limit])
      .map((r) => {for (final k in r.keys) k: r[k]})
      .toList();

  void markSynced(Iterable<int> ids) {
    if (ids.isEmpty) return;
    final at = _now().toUtc().toIso8601String();
    for (final id in ids) {
      _db.raw.execute('UPDATE audit_log SET synced_at = ? WHERE id = ?', [at, id]);
    }
  }

  int get unsyncedCount => _db.raw
      .select('SELECT COUNT(*) c FROM audit_log WHERE synced_at IS NULL')
      .first['c'] as int;
}
