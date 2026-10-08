import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';

import '../audit/audit_log.dart';
import '../db/database.dart';
import '../db/stress_purge.dart';
import 'cloud_client.dart';
import 'cloud_sync_state.dart';
import 'report_lookups.dart';

/// How one pass ended.
enum CloudSyncOutcome {
  /// Something was sent.
  synced,

  /// Nothing had changed.
  idle,

  /// No server or no pairing on this till.
  notConfigured,

  /// Another pass is already running.
  busy,

  /// The server could not be reached or refused. Tried again later.
  failed,
}

/// What the settings screen shows.
typedef CloudSyncStatus = ({
  bool running,
  int pending,
  DateTime? lastSuccessAt,
  String? lastError,
});

/// Sends the till's sales, shifts, clock-ins and audit trail to the shop's
/// server as they change, so the reports site reads the same figures the till
/// does.
///
/// The database notes every change in `cloud_pending` (schema v29); a pass
/// sends what is noted in batches and then forgets exactly the rows it sent.
/// The first pass after a pairing queues the whole history, since the server
/// it points at has none of it. Only this till's own sales go: every till on
/// the LAN holds the others' too, and each sends its own. Stress Lab orders
/// never leave the till. Selling never waits on any of it.
class CloudSyncService {
  CloudSyncService({
    required this.db,
    required this.state,
    required this.deviceId,
    required Future<({String url, String token})?> Function() connection,
    required ReportLookups Function() lookups,
    CloudClient Function(String baseUrl)? clientFor,
    AuditLog? audit,
    DateTime Function()? now,
    this.tick = const Duration(minutes: 1),
    this.retryAfter = const Duration(minutes: 2),
    this.batchSize = 500,
    this.maxBatches = 200,
  })  : _connection = connection,
        _lookups = lookups,
        _clientFor = clientFor ?? CloudClient.new,
        _audit = audit,
        _now = now ?? DateTime.now;

  final Db db;
  final CloudSyncStateStore state;
  final String deviceId;
  final Future<({String url, String token})?> Function() _connection;
  final ReportLookups Function() _lookups;
  final CloudClient Function(String baseUrl) _clientFor;
  final AuditLog? _audit;
  final DateTime Function() _now;

  /// How often the timer wakes to send what changed.
  final Duration tick;

  /// How long after a failed pass the next routine one may start.
  final Duration retryAfter;

  /// Records per request, at most the server's limit.
  final int batchSize;

  /// Batches in one pass, so a long history goes over several minutes rather
  /// than holding one pass open for an hour.
  final int maxBatches;

  Timer? _timer;
  Future<CloudSyncOutcome>? _running;
  String? _lastLogged;

  /// Bumped when a pass starts or ends, so an open screen can redraw.
  final ValueNotifier<int> changes = ValueNotifier(0);

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(tick, (_) => unawaited(_onTick()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Send at the next chance rather than at the next tick.
  void request() => unawaited(_onTick(force: true));

  /// Changes not sent yet.
  int get pending =>
      db.raw.select('SELECT COUNT(*) AS c FROM cloud_pending').first['c'] as int;

  CloudSyncStatus status() {
    final s = state.load();
    return (
      running: _running != null,
      pending: pending,
      lastSuccessAt: s.lastSuccessAt,
      lastError: s.lastError,
    );
  }

  /// Send what changed now, unless a pass is already running.
  Future<CloudSyncOutcome> runNow() {
    if (_running != null) return Future.value(CloudSyncOutcome.busy);
    final attempt = _attempt().whenComplete(() {
      _running = null;
      changes.value++;
    });
    _running = attempt;
    changes.value++;
    return attempt;
  }

  Future<void> _onTick({bool force = false}) async {
    if (_running != null) return;
    if (!force) {
      final s = state.load();
      if (s.lastError != null &&
          s.lastTryAt != null &&
          _now().difference(s.lastTryAt!) < retryAfter) {
        return;
      }
    }
    await runNow();
  }

  Future<CloudSyncOutcome> _attempt() async {
    final connection = await _connection();
    if (connection == null) {
      _forget();
      return CloudSyncOutcome.notConfigured;
    }
    final (:url, :token) = connection;
    final s = state.load();
    final client = _clientFor(url);
    try {
      s.lastTryAt = _now();
      final tag = crypto.sha256.convert(utf8.encode(token)).toString().substring(0, 16);
      if (s.historyFor != tag) {
        _queueHistory();
        s
          ..historyFor = tag
          ..lookupShas.clear();
        state.save(s);
      }

      var sent = 0;
      for (var i = 0; i < maxBatches; i++) {
        final rows = db.raw.select(
            'SELECT seq, kind, key FROM cloud_pending ORDER BY seq LIMIT ?',
            [batchSize]);
        if (rows.isEmpty) break;
        final records = [
          for (final r in rows)
            ?_record(r['kind'] as String, r['key'] as String),
        ];
        if (records.isNotEmpty) await client.sync(token, records);
        _drop([for (final r in rows) r['seq'] as int]);
        sent += records.length;
        if (rows.length < batchSize) break;
      }

      final shas = <String, String>{};
      final lookups = <Map<String, Object?>>[];
      for (final MapEntry(:key, :value) in _lookups().toRecords().entries) {
        final sha = _digest(value);
        if (s.lookupShas[key] == sha) continue;
        shas[key] = sha;
        // The server files these under the device's branch whatever key says.
        lookups.add({'kind': key, 'key': 'branch', 'at': null, 'payload': value});
      }
      if (lookups.isNotEmpty) {
        await client.sync(token, lookups);
        s.lookupShas.addAll(shas);
      }

      s
        ..lastSuccessAt = _now()
        ..lastError = null;
      _lastLogged = null;
      return sent + lookups.length > 0 ? CloudSyncOutcome.synced : CloudSyncOutcome.idle;
    } catch (e) {
      s.lastError = e is CloudError ? e.message : '$e';
      // Once per new reason, not every two minutes of an outage.
      if (s.lastError != _lastLogged) {
        _lastLogged = s.lastError;
        _audit?.record('system', 'cloud.sync.failed', detail: '$e');
      }
      return CloudSyncOutcome.failed;
    } finally {
      client.close();
      state.save(s);
    }
  }

  static String _digest(Object value) =>
      crypto.sha256.convert(utf8.encode(jsonEncode(value))).toString();

  /// Queue everything the till holds, for a server that has none of it.
  void _queueHistory() {
    db.raw.execute('BEGIN');
    try {
      db.raw.execute(
          "INSERT OR IGNORE INTO cloud_pending (kind, key) "
          "SELECT 'order', uuid FROM orders "
          "WHERE state IN ('paid', 'synced') AND device_id = ? "
          'ORDER BY created_at',
          [deviceId]);
      db.raw.execute("INSERT OR IGNORE INTO cloud_pending (kind, key) "
          "SELECT 'shift', id FROM shifts ORDER BY opened_at");
      db.raw.execute("INSERT OR IGNORE INTO cloud_pending (kind, key) "
          "SELECT 'attendance', CAST(id AS TEXT) FROM attendance ORDER BY id");
      db.raw.execute("INSERT OR IGNORE INTO cloud_pending (kind, key) "
          "SELECT 'audit', CAST(id AS TEXT) FROM audit_log ORDER BY id");
      db.raw.execute('COMMIT');
    } catch (_) {
      db.raw.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Unpaired: nothing noted is going anywhere, and the next pairing queues
  /// the whole history again anyway.
  void _forget() {
    if (pending > 0) db.raw.execute('DELETE FROM cloud_pending');
    final s = state.load();
    if (s.historyFor != null) {
      s
        ..historyFor = null
        ..lookupShas.clear();
      state.save(s);
    }
  }

  void _drop(List<int> seqs) {
    if (seqs.isEmpty) return;
    db.raw.execute('BEGIN');
    try {
      for (final seq in seqs) {
        db.raw.execute('DELETE FROM cloud_pending WHERE seq = ?', [seq]);
      }
      db.raw.execute('COMMIT');
    } catch (_) {
      db.raw.execute('ROLLBACK');
      rethrow;
    }
  }

  /// The record the server keeps for one noted change, or null when it is not
  /// this till's to send.
  Map<String, Object?>? _record(String kind, String key) => switch (kind) {
        'order' => _order(key),
        'shift' => _shift(key),
        'attendance' => _attendance(key),
        'audit' => _auditRow(key),
        _ => null,
      };

  Map<String, Object?>? _order(String uuid) {
    final rows = db.raw.select(
        'SELECT device_id, state, created_at, payload, payload LIKE ? AS stress '
        'FROM orders WHERE uuid = ?',
        [kStressNoteMatch, uuid]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    if (r['device_id'] != deviceId || r['stress'] == 1) return null;
    final order = jsonDecode(r['payload'] as String) as Map<String, dynamic>;
    return {
      'kind': 'order',
      'key': uuid,
      'at': r['created_at'],
      // The column is the truth: a reopened sale leaves the site's figures.
      'payload': {...order, 'state': r['state']},
    };
  }

  Map<String, Object?>? _shift(String id) {
    final rows = db.raw.select('SELECT * FROM shifts WHERE id = ?', [id]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return {
      'kind': 'shift',
      // Every till opens a drawer of its own when the shop's shift opens.
      'key': '$deviceId:$id',
      'at': r['opened_at'],
      'payload': {for (final k in r.keys) k: r[k]},
    };
  }

  Map<String, Object?>? _attendance(String id) {
    final rows = db.raw
        .select('SELECT * FROM attendance WHERE id = ?', [int.tryParse(id)]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return {
      'kind': 'attendance',
      // Clock-ins are shared over the LAN, so every till holds the same ones
      // under ids of its own; who and when is what they agree on.
      'key': '${r['staff_id']}|${r['clock_in']}',
      'at': r['clock_in'],
      'payload': {for (final k in r.keys) k: r[k]},
    };
  }

  Map<String, Object?>? _auditRow(String id) {
    final rows = db.raw
        .select('SELECT * FROM audit_log WHERE id = ?', [int.tryParse(id)]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return {
      'kind': 'audit',
      'key': '$deviceId:$id',
      'at': r['at'],
      'payload': {
        for (final k in r.keys)
          if (k != 'synced_at') k: r[k],
      },
    };
  }
}
