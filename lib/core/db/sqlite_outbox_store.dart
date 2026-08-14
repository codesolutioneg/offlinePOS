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

  /// Take an entry back out of the queue before it is delivered, so a record that
  /// is being rewritten locally cannot book the version that was queued.
  ///
  /// Returns false, touching nothing, when a row for this key exists and is past
  /// withdrawing: acknowledged by the server, or parked. The caller is expected to
  /// abandon whatever it was about to rewrite.
  ///
  /// Deleting is deliberate, and the alternatives are both wrong. Marking the row
  /// dead would strand the record forever, because [append] leaves `dead_at` alone
  /// on a conflict and [pending] skips dead rows, so the re-queue would land on a
  /// row nothing ever drains. Leaving the row to be overwritten by the re-queue
  /// would keep the superseded payload deliverable in the meantime, so a record
  /// that was withdrawn and then abandoned rather than re-saved would still be sent.
  /// With the row gone, nothing is owed until the record is saved again.
  bool withdrawPending(String kind, String payloadUuid) {
    // Unique on (kind, payload_uuid), so this is one row or none.
    final rows = _db.raw.select(
        'SELECT sent_at, dead_at FROM outbox WHERE kind = ? AND payload_uuid = ?',
        [kind, payloadUuid]);
    if (rows.isNotEmpty &&
        (rows.first['sent_at'] != null || rows.first['dead_at'] != null)) {
      return false;
    }
    _db.raw.execute(
        'DELETE FROM outbox WHERE kind = ? AND payload_uuid = ? '
        'AND sent_at IS NULL AND dead_at IS NULL',
        [kind, payloadUuid]);
    return true;
  }

  /// Put a parked entry back in the queue, once whatever caused it is fixed.
  void revive(int id) => _db.raw.execute(
      'UPDATE outbox SET dead_at = NULL, dead_reason = NULL, attempts = 0 WHERE id = ?',
      [id]);

  /// Age of the oldest thing still waiting, which is how long the books have been
  /// out of date.
  ///
  /// The heartbeat is excluded, and that exclusion is the whole point of this
  /// method being written out rather than being a one-line count. `device.status`
  /// is keyed on the device and re-queued every 30 s onto the same row, and
  /// [append] deliberately leaves `created_at` alone on a conflict, so that row
  /// keeps the timestamp of the very first launch. Counting it would make this
  /// return "time since this till was installed" the moment delivery stopped, and
  /// the red attention banner would latch on 24 hours after install and never
  /// clear. Support triages on this number; it has to mean the outage.
  Duration? oldestPendingAge(DateTime now) {
    final rows = _db.raw.select(
        'SELECT created_at FROM outbox WHERE sent_at IS NULL AND dead_at IS NULL '
        "AND kind <> '$_heartbeat' ORDER BY id LIMIT 1");
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

  /// Everything still owed to the server, heartbeat aside.
  ///
  /// The heartbeat is a snapshot of this queue keyed on the device, so it is
  /// replaced rather than accumulated and is never a backlog item. Counting it
  /// would make a fully caught-up till report one thing waiting, forever.
  int get pendingCount => _db.raw
      .select('SELECT COUNT(*) c FROM outbox WHERE sent_at IS NULL '
          "AND dead_at IS NULL AND kind <> '$_heartbeat'")
      .first['c'] as int;

  /// Sales specifically, which is the number a shop and its support actually mean
  /// when they ask how much is waiting. Audit rows are owed to the server too, but
  /// they are not takings.
  int get pendingSalesCount => _db.raw
      .select('SELECT COUNT(*) c FROM outbox WHERE sent_at IS NULL '
          "AND dead_at IS NULL AND kind = '$_order'")
      .first['c'] as int;

  /// Kinds are part of the on-disk contract; see docs/ODOO_SYNC.md.
  static const String _heartbeat = 'device.status';
  static const String _order = 'order.push';
}
