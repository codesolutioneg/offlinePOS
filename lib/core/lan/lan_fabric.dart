import 'dart:async';

import 'lan_applier.dart';
import 'lan_event.dart';
import 'lan_event_log.dart';
import 'lan_peer.dart';
import 'lan_transport.dart';

/// Keeps this till's shared state and its peers' in step, on the shop LAN and
/// nothing else.
///
/// Two directions, and only one of them is relied on. Pulling is the truth: each
/// till asks each peer for everything after the cursor it has on disk, so a device
/// that was off, asleep or on the wrong side of a dead switch catches up completely
/// the moment it can talk again. Pushing is only latency: it hands a change over
/// immediately so a second till is current in milliseconds, and a push that fails
/// is forgotten, because the pull behind it will deliver the same event anyway.
///
/// Nothing here is ever awaited by a selling screen. [publish] is a local insert
/// inside the store's own transaction and schedules the network work for after the
/// tap has finished; a dead peer, a slow peer or a peer that throws costs a log
/// line on a background timer.
class LanFabric {
  LanFabric({
    required this.deviceId,
    required LanEventLog log,
    required LanApplier applier,
    required this.peers,
    LanFetch? fetch,
    LanNotify? notify,
    LanLog? onError,
    this.pullInterval = const Duration(seconds: 5),
    this.pageSize = 200,
    DateTime Function()? now,
  })  : _log = log,
        _applier = applier,
        _fetch = fetch,
        _notify = notify,
        _onError = onError,
        _now = now ?? DateTime.now,
        // Whatever is already in the log has been on this till since before the
        // fabric started; a peer that wants it will pull it. Announcing the whole
        // history on every launch would be a burst that buys nothing.
        _notifiedUpTo = log.lastSeq;

  final String deviceId;
  final LanEventLog _log;
  final LanApplier _applier;

  /// Who is on the LAN. Fed by the beacon, and empty on a single-till shop.
  final LanPeerDirectory peers;

  final LanFetch? _fetch;
  final LanNotify? _notify;
  final LanLog? _onError;
  final DateTime Function() _now;

  /// How often this till asks its peers what it missed. Fast enough that a table
  /// opened on the other till colours in while a waiter is still walking, slow
  /// enough to be nothing on a shop LAN.
  final Duration pullInterval;

  final int pageSize;

  int _notifiedUpTo;
  Timer? _timer;
  bool _passing = false;
  bool _pushScheduled = false;

  /// When the last pass finished, for the LAN settings screen. Null until one has.
  DateTime? lastPassAt;

  /// What went wrong on the last pass, in the words support gets read back.
  String? lastError;

  /// Announce a committed local change.
  ///
  /// Called by the stores from inside their write transaction, so this must stay a
  /// single local insert: no awaits, no sockets, nothing that can fail slowly. The
  /// hand-over to the peers is scheduled for after the transaction has settled.
  void publish(LanEventKind kind, String recordUuid, Map<String, dynamic> payload) {
    _log.append(kind, recordUuid, payload);
    _schedulePush();
  }

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(pullInterval, (_) => unawaited(pass()));
    unawaited(pass());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One turn: read what the peers have, then hand over anything of ours they have
  /// not been told about. Never throws.
  Future<void> pass() async {
    if (_passing) return;
    _passing = true;
    try {
      await pullAll();
      await pushPending();
      lastPassAt = _now().toUtc();
    } finally {
      _passing = false;
    }
  }

  /// Catch up from every peer, each from its own durable cursor.
  ///
  /// A peer that throws, times out or answers nonsense is logged and skipped: the
  /// next pass tries it again, and the tills that did answer are already applied.
  Future<void> pullAll() async {
    final fetch = _fetch;
    if (fetch == null) return;
    for (final peer in peers.active) {
      try {
        // A page at a time until the peer has nothing newer, bounded so one very
        // stale peer cannot own this pass forever.
        for (var page = 0; page < maxPagesPerPass; page++) {
          final since = _log.cursorFor(peer.deviceId);
          final reply = await fetch(peer, since);
          _applier.applyAll(peer.deviceId, reply.events, highSeq: reply.highSeq);
          if (reply.events.isEmpty) break;
        }
        lastError = null;
      } catch (e) {
        lastError = '${peer.name}: $e';
        _onError?.call('lan.pull.failed', '${peer.deviceId} (${peer.name}): $e');
      }
    }
  }

  /// Hand everything appended since the last hand-over to every peer.
  ///
  /// The mark moves even when a peer refused it. A notify is a shortcut, not a
  /// delivery guarantee: the peer's cursor is on its disk, so what it missed here
  /// it collects on its own next pull.
  Future<void> pushPending() async {
    final notify = _notify;
    if (notify == null) return;
    final targets = peers.active;
    if (targets.isEmpty) return;
    final events = _log.since(_notifiedUpTo, limit: pageSize);
    if (events.isEmpty) return;
    for (final peer in targets) {
      try {
        await notify(peer, events);
      } catch (e) {
        _onError?.call('lan.notify.failed', '${peer.deviceId} (${peer.name}): $e');
      }
    }
    _notifiedUpTo = events.last.seq;
  }

  /// Push once the current tap is over.
  ///
  /// A microtask, so it runs after the store's transaction has committed (or rolled
  /// back) and after the sale has been handed back to the cashier. It also reads the
  /// events to send from the log rather than from memory, which is why a rolled-back
  /// append can never be announced.
  void _schedulePush() {
    if (_pushScheduled) return;
    _pushScheduled = true;
    scheduleMicrotask(() {
      _pushScheduled = false;
      unawaited(pushPending());
    });
  }

  /// Pages one peer may take in a single pass. A till back from a week away is
  /// caught up over a few passes rather than one long run.
  static const int maxPagesPerPass = 10;
}
