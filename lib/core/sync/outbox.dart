import 'dart:async';

/// One thing that must eventually reach the server.
class OutboxEntry {
  OutboxEntry({
    required this.id,
    required this.kind,
    required this.payloadUuid,
    required this.payload,
    this.attempts = 0,
    this.lastError,
  });

  final int id;

  /// e.g. 'order.push'. Determines which sender handles it.
  final String kind;

  /// The client UUID of the record. Makes the send idempotent.
  final String payloadUuid;

  final Map<String, dynamic> payload;
  int attempts;
  String? lastError;
}

/// Raised by a sender when retrying cannot help: a validation failure, a deleted
/// product, a rejected reference. The entry is parked, not retried forever.
class PermanentlyRejected implements Exception {
  PermanentlyRejected(this.reason);
  final String reason;
  @override
  String toString() => 'PermanentlyRejected: $reason';
}

/// Where entries live between being written and being accepted by the server.
abstract class OutboxStore {
  Future<void> append(String kind, String payloadUuid, Map<String, dynamic> payload);
  Future<List<OutboxEntry>> pending({int limit});
  Future<void> markSent(int id);
  Future<void> markFailed(int id, String error);

  /// Park an entry that can never succeed, so the queue behind it can move.
  Future<void> markDead(int id, String reason);
}

/// Sends one entry. Must be idempotent: the same payloadUuid may arrive twice
/// because a drain can be interrupted after the server committed but before we
/// recorded the acknowledgement.
typedef OutboxSender = Future<void> Function(OutboxEntry entry);

/// Drains the outbox in order, and never blocks selling.
///
/// Deliberately dumb: no merging, no reconciliation, no server-to-client writes.
/// The till owns its sales; the server is a destination. That removes the entire
/// class of conflict bugs a two-way sync would introduce.
class Outbox {
  Outbox({
    required OutboxStore store,
    required Map<String, OutboxSender> senders,
    this.batchSize = 20,
    this.maxAttempts = 25,
  })  : _store = store,
        _senders = senders;

  final OutboxStore _store;
  final Map<String, OutboxSender> _senders;
  final int batchSize;

  /// Attempts before a repeatedly failing entry is parked. Generous, because a
  /// long outage must not be mistaken for a bad order. 0 disables parking.
  final int maxAttempts;

  bool _draining = false;

  /// Queue something for delivery. Returns as soon as it is durable.
  Future<void> enqueue(String kind, String payloadUuid, Map<String, dynamic> payload) {
    return _store.append(kind, payloadUuid, payload);
  }

  /// Drain until the queue is empty or the line goes away.
  ///
  /// After a week offline there can be thousands of entries, so this keeps going
  /// rather than doing one batch per tick, which would be over an hour of pure
  /// pacing. [maxBatches] bounds a single call so the caller stays responsive.
  Future<int> drain({int maxBatches = 1000}) async {
    if (_draining) return 0;
    _draining = true;
    var sent = 0;
    try {
      for (var i = 0; i < maxBatches; i++) {
        final batch = await _store.pending(limit: batchSize);
        if (batch.isEmpty) break;
        final result = await _drainBatch(batch);
        sent += result.sent;
        // A transient failure means the line is down: stop, keeping the order of
        // whatever is left, rather than spinning against a dead network.
        if (result.stopped) break;
        // Nothing moved and nothing was parked: no progress is possible now.
        if (result.sent == 0 && result.parked == 0) break;
      }
    } finally {
      _draining = false;
    }
    return sent;
  }

  Future<_BatchResult> _drainBatch(List<OutboxEntry> batch) async {
    var sent = 0;
    var parked = 0;
    for (final entry in batch) {
      final sender = _senders[entry.kind];
      if (sender == null) {
        // Nothing can ever handle this. Park it rather than block the queue.
        await _store.markDead(entry.id, 'no sender for kind ${entry.kind}');
        parked++;
        continue;
      }
      try {
        await sender(entry);
        await _store.markSent(entry.id);
        sent++;
      } on PermanentlyRejected catch (e) {
        // The server understood and refused. Retrying cannot help, and blocking
        // everything behind it would strand the rest of the week's takings.
        await _store.markDead(entry.id, e.reason);
        parked++;
      } catch (e) {
        await _store.markFailed(entry.id, e.toString());
        if (maxAttempts > 0 && entry.attempts + 1 >= maxAttempts) {
          await _store.markDead(entry.id, 'gave up after ${entry.attempts + 1}: $e');
          parked++;
          continue;
        }
        // Treat as the line being down: preserve order and try again later.
        return _BatchResult(sent: sent, parked: parked, stopped: true);
      }
    }
    return _BatchResult(sent: sent, parked: parked, stopped: false);
  }
}

class _BatchResult {
  const _BatchResult({required this.sent, required this.parked, required this.stopped});
  final int sent;
  final int parked;
  final bool stopped;
}
