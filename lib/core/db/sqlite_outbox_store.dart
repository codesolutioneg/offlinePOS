import 'dart:convert';

import '../sync/outbox.dart';
import 'database.dart';

/// Durable [OutboxStore]. Nothing leaves it until the server has acknowledged.
class SqliteOutboxStore implements OutboxStore {
  SqliteOutboxStore(this._db);

  final Db _db;

  @override
  Future<void> append(String kind, String payloadUuid, Map<String, dynamic> payload) async {
    // Re-queuing the same record replaces the payload rather than adding a second
    // entry, so a redraw or an edit cannot turn one sale into two deliveries.
    _db.raw.execute(
      '''
      INSERT INTO outbox (kind, payload_uuid, payload, created_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(kind, payload_uuid) DO UPDATE SET
        payload    = excluded.payload,
        sent_at    = NULL,
        last_error = NULL
      ''',
      [kind, payloadUuid, jsonEncode(payload), DateTime.now().toUtc().toIso8601String()],
    );
  }

  @override
  Future<List<OutboxEntry>> pending({int limit = 20}) async {
    final rows = _db.raw.select(
      'SELECT id, kind, payload_uuid, payload, attempts, last_error '
      'FROM outbox WHERE sent_at IS NULL AND dead_at IS NULL ORDER BY id ASC LIMIT ?',
      [limit],
    );
    return rows
        .map((r) => OutboxEntry(
              id: r['id'] as int,
              kind: r['kind'] as String,
              payloadUuid: r['payload_uuid'] as String,
              payload: jsonDecode(r['payload'] as String) as Map<String, dynamic>,
              attempts: r['attempts'] as int,
              lastError: r['last_error'] as String?,
            ))
        .toList();
  }

  @override
  Future<void> markSent(int id) async {
    _db.raw.execute('UPDATE outbox SET sent_at = ? WHERE id = ?',
        [DateTime.now().toUtc().toIso8601String(), id]);
  }

  @override
  Future<void> markDead(int id, String reason) async {
    _db.raw.execute(
        'UPDATE outbox SET dead_at = ?, dead_reason = ? WHERE id = ?',
        [DateTime.now().toUtc().toIso8601String(), reason, id]);
  }

  /// Parked entries. Each one is money that never reached the books, so this is
  /// surfaced on the till and in the heartbeat rather than quietly counted.
  List<OutboxEntry> dead({int limit = 100}) => _db.raw
      .select(
          'SELECT id, kind, payload_uuid, payload, attempts, dead_reason '
          'FROM outbox WHERE dead_at IS NOT NULL ORDER BY id LIMIT ?', [limit])
      .map((r) => OutboxEntry(
            id: r['id'] as int,
            kind: r['kind'] as String,
            payloadUuid: r['payload_uuid'] as String,
            payload: jsonDecode(r['payload'] as String) as Map<String, dynamic>,
            attempts: r['attempts'] as int,
            lastError: r['dead_reason'] as String?,
          ))
      .toList();

  int get deadCount => _db.raw
      .select('SELECT COUNT(*) c FROM outbox WHERE dead_at IS NOT NULL')
      .first['c'] as int;

  /// Put a parked entry back in the queue, once whatever caused it is fixed.
  void revive(int id) => _db.raw.execute(
      'UPDATE outbox SET dead_at = NULL, dead_reason = NULL, attempts = 0 WHERE id = ?',
      [id]);

  /// Age of the oldest thing still waiting, which is how long the books have been
  /// out of date.
  Duration? oldestPendingAge(DateTime now) {
    final rows = _db.raw.select(
        'SELECT created_at FROM outbox WHERE sent_at IS NULL AND dead_at IS NULL '
        'ORDER BY id LIMIT 1');
    if (rows.isEmpty) return null;
    return now.difference(DateTime.parse(rows.first['created_at'] as String));
  }

  @override
  Future<void> markFailed(int id, String error) async {
    _db.raw.execute(
        'UPDATE outbox SET attempts = attempts + 1, last_error = ? WHERE id = ?',
        [error, id]);
  }

  /// Entries the server has taken. Kept for a while so a duplicate push can be
  /// recognised, then pruned.
  int pruneSent({Duration olderThan = const Duration(days: 7)}) {
    final cutoff = DateTime.now().toUtc().subtract(olderThan).toIso8601String();
    _db.raw.execute('DELETE FROM outbox WHERE sent_at IS NOT NULL AND sent_at < ?', [cutoff]);
    return _db.raw.updatedRows;
  }

  int get pendingCount => _db.raw
      .select('SELECT COUNT(*) c FROM outbox WHERE sent_at IS NULL AND dead_at IS NULL')
      .first['c'] as int;
}
