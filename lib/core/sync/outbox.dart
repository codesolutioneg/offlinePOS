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

/// Where entries live between being written and being accepted by the server.
abstract class OutboxStore {
  Future<void> append(String kind, String payloadUuid, Map<String, dynamic> payload);
  Future<List<OutboxEntry>> pending({int limit});
  Future<void> markSent(int id);
  Future<void> markFailed(int id, String error);
}

/// Sends one entry. Must be idempotent: the same payloadUuid may arrive twice
/// because a drain can be interrupted after the server committed but before we
/// recorded the acknowledgement.
typedef OutboxSender = Future<void> Function(OutboxEntry entry);

/// Drains the outbox in order, with backoff, and never blocks selling.
///
/// Deliberately dumb: no merging, no reconciliation, no server-to-client writes.
/// The till owns its sales; the server is a destination. That removes the entire
/// class of conflict bugs a two-way sync would introduce.
class Outbox {
  Outbox({
    required OutboxStore store,
    required Map<String, OutboxSender> senders,
    this.batchSize = 20,
    this.maxAttempts = 0,
  })  : _store = store,
        _senders = senders;

  final OutboxStore _store;
  final Map<String, OutboxSender> _senders;
  final int batchSize;

  /// 0 means retry forever. An order must never be dropped because the line was
  /// down for a long time.
  final int maxAttempts;

  bool _draining = false;

  /// Queue something for delivery. Returns as soon as it is durable.
  Future<void> enqueue(String kind, String payloadUuid, Map<String, dynamic> payload) {
    return _store.append(kind, payloadUuid, payload);
  }

  /// Attempt one pass. Safe to call often; overlapping calls are ignored.
  /// Returns the number of entries accepted by the server.
  Future<int> drain() async {
    if (_draining) return 0;
    _draining = true;
    var sent = 0;
    try {
      final batch = await _store.pending(limit: batchSize);
      for (final entry in batch) {
        final sender = _senders[entry.kind];
        if (sender == null) {
          await _store.markFailed(entry.id, 'no sender for kind ${entry.kind}');
          continue;
        }
        try {
          await sender(entry);
          await _store.markSent(entry.id);
          sent++;
        } catch (e) {
          await _store.markFailed(entry.id, e.toString());
          // Order matters, so stop on the first failure rather than reordering
          // the queue behind a stuck entry.
          break;
        }
      }
    } finally {
      _draining = false;
    }
    return sent;
  }

  /// Entries that have exceeded maxAttempts and need a human.
  bool isStuck(OutboxEntry e) => maxAttempts > 0 && e.attempts >= maxAttempts;
}
