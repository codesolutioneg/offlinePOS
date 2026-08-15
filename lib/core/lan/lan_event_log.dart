import 'dart:convert';

import '../db/database.dart';
import 'lan_event.dart';

/// This till's append-only event log, the per-peer read cursors, and the clock the
/// conflict rule is decided on.
///
/// Only locally originated events are written here. A till serves its own log to
/// its peers and nothing else, which is what keeps replication from looping: an
/// event has exactly one origin and travels exactly one hop.
///
/// Every write is a plain local statement, so appending an event costs a cashier
/// nothing. Nothing in this class opens a socket.
class LanEventLog {
  LanEventLog(this._db, {required this.deviceId, DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final Db _db;

  /// This device's id, stamped as the origin on everything it appends.
  final String deviceId;

  final DateTime Function() _now;

  /// Record a local change. Call this inside the same transaction as the store
  /// write it describes, so the two cannot come apart: an event for a record that
  /// was rolled back would announce a sale that does not exist.
  LanEvent append(
    LanEventKind kind,
    String recordUuid,
    Map<String, dynamic> payload, {
    DateTime? at,
  }) {
    final stamp = (at ?? _now()).toUtc();
    if (kind.snapshot) {
      // A snapshot supersedes its predecessor, so the log holds one row per record
      // instead of one per tap. Safe against the cursor rule: a peer moves to the
      // high-water mark the page reports, which never goes backwards, so a row that
      // is gone is a gap and not a stall.
      _db.raw.execute(
        'DELETE FROM lan_events WHERE kind = ? AND record_uuid = ?',
        [kind.wire, recordUuid],
      );
    }
    _db.raw.execute(
      'INSERT INTO lan_events (kind, record_uuid, payload, at) VALUES (?,?,?,?)',
      [kind.wire, recordUuid, jsonEncode(payload), stamp.toIso8601String()],
    );
    final seq = _db.raw.lastInsertRowId;
    stampClock(recordUuid, kind, stamp, deviceId);
    return LanEvent(
      kind: kind,
      originDeviceId: deviceId,
      seq: seq,
      recordUuid: recordUuid,
      payload: payload,
      at: stamp,
    );
  }

  /// Everything after [seq], oldest first. What a peer asks for when it rejoins.
  ///
  /// [limit] bounds one answer so a till that has been off for a week catches up
  /// over several requests instead of one reply big enough to stall the LAN.
  List<LanEvent> since(int seq, {int limit = 200}) => [
        for (final row in _db.raw.select(
            'SELECT * FROM lan_events WHERE seq > ? ORDER BY seq LIMIT ?',
            [seq, limit]))
          ?_map(row),
      ];

  /// The newest local seq, or 0 on a till that has announced nothing yet.
  int get lastSeq =>
      _db.raw.select('SELECT COALESCE(MAX(seq), 0) s FROM lan_events').first['s']
          as int;

  int get count =>
      _db.raw.select('SELECT COUNT(*) c FROM lan_events').first['c'] as int;

  /// How far this till has read [peerDeviceId]'s log. 0 means never, which is the
  /// right starting point: the peer's whole log is a set of upserts, so replaying
  /// it from the beginning converges rather than duplicating.
  int cursorFor(String peerDeviceId) {
    final rows = _db.raw.select(
        'SELECT last_seq FROM lan_cursors WHERE peer_device_id = ?',
        [peerDeviceId]);
    return rows.isEmpty ? 0 : rows.first['last_seq'] as int;
  }

  /// Advance the cursor for a peer. Never moves backwards: a reply that arrives out
  /// of order must not make this till re-read events it has already applied.
  void setCursor(String peerDeviceId, int seq) {
    if (seq <= cursorFor(peerDeviceId)) return;
    _db.raw.execute(
      'INSERT INTO lan_cursors (peer_device_id, last_seq, updated_at) VALUES (?,?,?) '
      'ON CONFLICT(peer_device_id) DO UPDATE SET last_seq = excluded.last_seq, '
      'updated_at = excluded.updated_at',
      [peerDeviceId, seq, _now().toUtc().toIso8601String()],
    );
  }

  /// Peer device id to the last seq applied from it, for the LAN settings screen.
  Map<String, int> cursors() => {
        for (final r in _db.raw.select(
            'SELECT peer_device_id, last_seq FROM lan_cursors ORDER BY peer_device_id'))
          r['peer_device_id'] as String: r['last_seq'] as int,
      };

  /// When this record was last written and by which till, or null if it has never
  /// been part of the fabric. The input to the last-write-wins rule.
  ({DateTime at, String origin})? clockFor(String recordUuid) {
    final rows = _db.raw
        .select('SELECT at, origin FROM lan_clocks WHERE record_uuid = ?', [recordUuid]);
    if (rows.isEmpty) return null;
    return (
      at: DateTime.parse(rows.first['at'] as String).toUtc(),
      origin: rows.first['origin'] as String,
    );
  }

  /// Remember who last wrote a record and when. [append] does this for a local
  /// change; the applier calls it directly for one that arrived from a peer.
  void stampClock(
          String recordUuid, LanEventKind kind, DateTime at, String origin) =>
      _db.raw.execute(
        'INSERT INTO lan_clocks (record_uuid, kind, at, origin) VALUES (?,?,?,?) '
        'ON CONFLICT(record_uuid) DO UPDATE SET kind = excluded.kind, '
        'at = excluded.at, origin = excluded.origin',
        [recordUuid, kind.wire, at.toIso8601String(), origin],
      );

  /// Null for a row whose kind this build does not know, which is only possible
  /// after a downgrade. Skipped rather than thrown on: a peer catching up must not
  /// be stopped by one row it could never apply anyway.
  LanEvent? _map(Map<String, Object?> r) {
    final kind = LanEventKind.fromWire(r['kind'] as String);
    if (kind == null) return null;
    return LanEvent(
      kind: kind,
      originDeviceId: deviceId,
      seq: r['seq'] as int,
      recordUuid: r['record_uuid'] as String,
      payload: (jsonDecode(r['payload'] as String) as Map).cast<String, dynamic>(),
      at: DateTime.parse(r['at'] as String).toUtc(),
    );
  }
}
