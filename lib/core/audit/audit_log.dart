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

  /// Recent entries, newest first, optionally filtered by [event], [actor] and a
  /// time window. Backs the manager's audit viewer and the activity report. Times
  /// are compared as UTC ISO strings, which sort lexically the same as
  /// chronologically.
  List<Map<String, Object?>> recent({
    int limit = 500,
    String? event,
    String? actor,
    DateTime? from,
    DateTime? to,
  }) {
    final where = <String>[];
    final args = <Object?>[];
    if (event != null) {
      where.add('event = ?');
      args.add(event);
    }
    if (actor != null) {
      where.add('actor = ?');
      args.add(actor);
    }
    if (from != null) {
      where.add('at >= ?');
      args.add(from.toUtc().toIso8601String());
    }
    if (to != null) {
      where.add('at <= ?');
      args.add(to.toUtc().toIso8601String());
    }
    final clause = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')} ';
    args.add(limit);
    return _db.raw
        .select('SELECT * FROM audit_log ${clause}ORDER BY id DESC LIMIT ?', args)
        .map((r) => {for (final k in r.keys) k: r[k]})
        .toList();
  }

  /// The distinct event kinds recorded, for a filter dropdown.
  List<String> events() => _db.raw
      .select('SELECT DISTINCT event FROM audit_log ORDER BY event')
      .map((r) => r['event'] as String)
      .toList();

  /// The distinct actors recorded, for a filter dropdown. Under one shared Odoo
  /// login the cashier id is the only record of who took an action, so this is
  /// how a manager narrows the trail to a single person.
  List<String> actors() => _db.raw
      .select('SELECT DISTINCT actor FROM audit_log ORDER BY actor')
      .map((r) => r['actor'] as String)
      .toList();
}
