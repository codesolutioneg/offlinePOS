import 'dart:convert';

import '../sync/outbox.dart';
import 'database.dart';
import 'stress_purge.dart';

/// Durable [OutboxStore]. Nothing leaves it until the server has acknowledged.
class SqliteOutboxStore implements OutboxStore {
  SqliteOutboxStore(this._db);

  final Db _db;

  /// The same handle the till is already using, so a support console can inspect
  /// and patch rows without opening a second connection onto the encrypted file.
  Db get db => _db;

  @override
  Future<void> append(String kind, String payloadUuid, Map<String, dynamic> payload) async {
    // Re-queuing the same record replaces the payload rather than adding a second
    // entry, so a redraw or an edit cannot turn one sale into two deliveries.
    //
    // The replacement also takes a fresh id, which is what makes the id a version.
    // A send already on the wire holds the old id, so its [markSent] finds no row
    // and the newer payload stays owed; without this the send of the old payload
    // would mark the new one delivered and it would never go out.
    _db.raw.execute(
      '''
      INSERT INTO outbox (kind, payload_uuid, payload, created_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(kind, payload_uuid) DO UPDATE SET
        id         = (SELECT MAX(id) FROM outbox) + 1,
        payload    = excluded.payload,
        sent_at    = NULL,
        last_error = NULL
      ''',
      [kind, payloadUuid, jsonEncode(payload), DateTime.now().toUtc().toIso8601String()],
    );
  }

  /// Stress Lab rows stay queued, so a run can check every sale reached the queue,
  /// but nothing ever hands them to a sender.
  @override
  Future<List<OutboxEntry>> pending({int limit = 20, Set<String>? kinds}) async {
    final filtered = kinds != null && kinds.isNotEmpty;
    final rows = filtered
        ? _db.raw.select(
            'SELECT id, kind, payload_uuid, payload, attempts, last_error '
            'FROM outbox WHERE sent_at IS NULL AND dead_at IS NULL '
            'AND payload NOT LIKE ? '
            'AND kind IN (${List.filled(kinds.length, '?').join(',')}) '
            'ORDER BY id ASC LIMIT ?',
            [kStressNoteMatch, ...kinds, limit],
          )
        : _db.raw.select(
            'SELECT id, kind, payload_uuid, payload, attempts, last_error '
            'FROM outbox WHERE sent_at IS NULL AND dead_at IS NULL '
            'AND payload NOT LIKE ? ORDER BY id ASC LIMIT ?',
            [kStressNoteMatch, limit],
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

  /// Mark several rows sent in one synchronous step, so a caller can put it inside
  /// its own transaction with the writes it has to agree with.
  void markAllSent(Iterable<int> ids) {
    final at = DateTime.now().toUtc().toIso8601String();
    for (final id in ids) {
      _db.raw.execute('UPDATE outbox SET sent_at = ? WHERE id = ?', [at, id]);
    }
  }

  @override
  Future<void> markDead(int id, String reason) async {
    _db.raw.execute(
        'UPDATE outbox SET dead_at = ?, dead_reason = ? WHERE id = ?',
        [DateTime.now().toUtc().toIso8601String(), reason, id]);
  }

  /// Parked entries. Each one is money that never reached the books, so this is
  /// surfaced on the till and in the heartbeat rather than quietly counted.
  /// [withoutSessionHolds] leaves out sales [holdSession] parked, so a large
  /// rejected session does not use up the [limit].
  List<OutboxEntry> dead({int limit = 100, bool withoutSessionHolds = false}) => _db.raw
      .select(
          'SELECT id, kind, payload_uuid, payload, attempts, dead_reason '
          'FROM outbox WHERE dead_at IS NOT NULL '
          '${withoutSessionHolds ? 'AND NOT (kind = ? AND substr(dead_reason, 1, ?) = ?) ' : ''}'
          'ORDER BY id LIMIT ?', [
        if (withoutSessionHolds) ...[orderPush, _sessionHold.length, _sessionHold],
        limit,
      ])
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

  /// Drop every outbox row for this sale push, sent or not. Used when another
  /// till has already booked the ticket into Odoo (shop-wide session resend) so
  /// this till must not push it again under a second sale order.
  void forgetOrderPush(String payloadUuid) {
    _db.raw.execute(
        "DELETE FROM outbox WHERE kind = '$orderPush' AND payload_uuid = ?",
        [payloadUuid]);
  }

  /// Park every sale still owed to Odoo, with [reason]. They stay in the queue,
  /// unsent, and show in the refused count until a manager revives them. Returns
  /// how many were held.
  int holdPendingSales(String reason) {
    _db.raw.execute(
        "UPDATE outbox SET dead_at = ?, dead_reason = ? WHERE kind = '$orderPush' "
        'AND sent_at IS NULL AND dead_at IS NULL',
        [DateTime.now().toUtc().toIso8601String(), reason]);
    return _db.raw.updatedRows;
  }

  /// Park the sales in [uuids] still owed to Odoo, with [reason], as
  /// [holdPendingSales] does for every one.
  void holdSales(Iterable<String> uuids, String reason) {
    final at = DateTime.now().toUtc().toIso8601String();
    for (final uuid in uuids) {
      _db.raw.execute(
          "UPDATE outbox SET dead_at = ?, dead_reason = ? WHERE kind = '$orderPush' "
          'AND payload_uuid = ? AND sent_at IS NULL AND dead_at IS NULL',
          [at, reason, uuid]);
    }
  }

  /// Park the sales in [uuids] because the server rejected the batch booked
  /// under [batchKey]. They come back only together, through [reviveSession],
  /// so the session is never booked in parts.
  void holdSession(String batchKey, Iterable<String> uuids, String reason) =>
      holdSales(uuids, '$_sessionHold$batchKey: $reason');

  /// Which of [uuids] are parked by [holdSession].
  Set<String> sessionHeldOf(Iterable<String> uuids) {
    final wanted = uuids.toSet();
    if (wanted.isEmpty) return const {};
    return {
      for (final r in _db.raw.select(
          'SELECT payload_uuid FROM outbox WHERE kind = ? AND dead_at IS NOT NULL '
          'AND substr(dead_reason, 1, ?) = ?',
          [orderPush, _sessionHold.length, _sessionHold]))
        if (wanted.contains(r['payload_uuid'])) r['payload_uuid'] as String,
    };
  }

  /// Every session parked by [holdSession]: its key, how many sales it holds,
  /// and why the server refused it.
  List<({String batchKey, int count, String reason})> heldSessions() {
    final found = <String, ({String batchKey, int count, String reason})>{};
    for (final r in _db.raw.select(
        'SELECT dead_reason FROM outbox WHERE kind = ? AND dead_at IS NOT NULL '
        'AND substr(dead_reason, 1, ?) = ? ORDER BY id',
        [orderPush, _sessionHold.length, _sessionHold])) {
      final text = (r['dead_reason'] as String).substring(_sessionHold.length);
      final colon = text.indexOf(': ');
      final key = colon < 0 ? text : text.substring(0, colon);
      final reason = colon < 0 ? '' : text.substring(colon + 2);
      final seen = found[key];
      found[key] = (
        batchKey: key,
        count: (seen?.count ?? 0) + 1,
        reason: seen?.reason ?? reason,
      );
    }
    return found.values.toList();
  }

  /// Put every sale [holdSession] parked under [batchKey] back in the queue.
  void reviveSession(String batchKey) {
    final prefix = '$_sessionHold$batchKey: ';
    _db.raw.execute(
        'UPDATE outbox SET dead_at = NULL, dead_reason = NULL, attempts = 0 '
        'WHERE kind = ? AND dead_at IS NOT NULL AND substr(dead_reason, 1, ?) = ?',
        [orderPush, prefix.length, prefix]);
  }

  /// Close out refund pushes queued before refunds stopped going to Odoo. Nothing
  /// sends them (the merge leaves credits out), so left alone they would sit in the
  /// pending count forever. Returns how many were closed.
  int retireRefundPushes() {
    _db.raw.execute(
        "UPDATE outbox SET sent_at = ? WHERE kind = '$orderPush' AND sent_at IS NULL "
        r"AND json_extract(payload, '$.refund_of_uuid') IS NOT NULL",
        [DateTime.now().toUtc().toIso8601String()]);
    return _db.raw.updatedRows;
  }

  /// Put a parked entry back in the queue, once whatever caused it is fixed.
  void revive(int id) => _db.raw.execute(
      'UPDATE outbox SET dead_at = NULL, dead_reason = NULL, attempts = 0 WHERE id = ?',
      [id]);

  /// [revive] by key, for a caller that just re-queued the record and knows it
  /// by uuid rather than by row id. [append] leaves `dead_at` alone, so without
  /// this a refused row would take the new payload and still never drain.
  void reviveByKey(String kind, String payloadUuid) => _db.raw.execute(
      'UPDATE outbox SET dead_at = NULL, dead_reason = NULL, attempts = 0 '
      'WHERE kind = ? AND payload_uuid = ? AND dead_at IS NOT NULL',
      [kind, payloadUuid]);

  /// Where each of [uuids] stands for [kind]: delivered, still waiting, or
  /// refused. A uuid with no row at all is in none of the three.
  ({Set<String> sent, Set<String> waiting, Set<String> refused}) statesOf(
      String kind, Iterable<String> uuids) {
    final sent = <String>{};
    final waiting = <String>{};
    final refused = <String>{};
    final wanted = uuids.toSet();
    if (wanted.isEmpty) return (sent: sent, waiting: waiting, refused: refused);
    final rows = _db.raw.select(
        'SELECT payload_uuid, sent_at, dead_at FROM outbox WHERE kind = ?', [kind]);
    for (final r in rows) {
      final uuid = r['payload_uuid'] as String;
      if (!wanted.contains(uuid)) continue;
      if (r['dead_at'] != null) {
        refused.add(uuid);
      } else if (r['sent_at'] != null) {
        sent.add(uuid);
      } else {
        waiting.add(uuid);
      }
    }
    return (sent: sent, waiting: waiting, refused: refused);
  }

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
          "AND dead_at IS NULL AND kind = '$orderPush'")
      .first['c'] as int;

  /// Paid sales still waiting to reach Dishflow's owner view, and the bags still
  /// waiting to reach their driver's app.
  int get pendingDishflowCount => _db.raw
      .select('SELECT COUNT(*) c FROM outbox WHERE sent_at IS NULL '
          "AND dead_at IS NULL AND kind IN ('$_dishflow', '$_driver')")
      .first['c'] as int;

  /// Sales, mirror copies and driver bags the server refused, heartbeat and audit
  /// aside. They leave the pending count when refused, so without their own count
  /// a refusal would read as delivered.
  int get refusedCount => _db.raw
      .select('SELECT COUNT(*) c FROM outbox WHERE dead_at IS NOT NULL '
          "AND kind IN ('$orderPush', '$_dishflow', '$_driver')")
      .first['c'] as int;

  /// Kinds are part of the on-disk contract; see docs/ODOO_SYNC.md.
  static const String _heartbeat = 'device.status';
  static const String orderPush = 'order.push';
  static const String _sessionHold = 'held session ';
  static const String _dishflow = 'dishflow.sale.push';
  static const String _driver = 'dishflow.driver.order.push';
}
