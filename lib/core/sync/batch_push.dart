import '../db/sqlite_outbox_store.dart';
import 'batch_merge.dart';

/// Sends a shift's sales to Odoo as one merged sales order, when the shop has
/// asked for that and the server can take it.
///
/// Runs before the ordinary drain at a shift close and on the armed retry, never
/// on the read-only timer and never on the path of a sale. Everything it can
/// refuse to do, it refuses by doing nothing: the per-sale push behind it is
/// always the safe answer.
///
/// **Recovering a partial failure.** The batch is all or nothing on the till side.
/// The merged payload goes out first and only when the server has acknowledged it
/// are the outbox rows marked sent and the sales marked synced. A close that fails
/// anywhere before that leaves every sale queued exactly as it was, and the next
/// attempt (the armed retry, a manual Sync now, the next close) rebuilds the same
/// payload under the same shift uuid. That repeat is what the server has to
/// recognise: it is the only thing standing between a timeout after the commit and
/// a night booked twice. If the batch is re-cut in between, because one sale was
/// parked or a late one joined, the key stays the same and the per-ticket uuids
/// inside it are what let the server settle the difference rather than book the
/// overlap again. That is the part of the module change that cannot be skipped: a
/// server that only recognised the batch key would answer `duplicate` to a re-cut
/// batch and the till would mark sales booked that never were.
class BatchPush {
  BatchPush({
    required this.outboxStore,
    required this.send,
    required this.enabled,
    required this.batchUuid,
    required this.onOrderBooked,
    this.maxOrders = 500,
  });

  final SqliteOutboxStore outboxStore;

  /// Delivers one merged payload under its own uuid. Throws the way the order
  /// sender does: transient keeps the sales, permanent parks nothing here (the
  /// sales stay queued and go out one at a time on the next pass).
  final Future<void> Function(String uuid, Map<String, dynamic> payload) send;

  /// Whether the shop has turned merging on. Read every time rather than captured,
  /// because a manager can change it between two closes.
  final bool Function() enabled;

  /// The shift the batch belongs to, which is where its idempotency key comes
  /// from. Null when there is no shift to key on, and then nothing is merged.
  final String? Function() batchUuid;

  /// Marks one constituent sale synced, so the history badge is honest and the
  /// pre-push sweep does not queue it all over again.
  final void Function(String uuid) onOrderBooked;

  /// How many queued entries a merged payload may be built over. A week of
  /// backlog is a lot of json for one request, and a batch that times out on its
  /// size would retry at the same size forever; past this the sales go out the
  /// ordinary way.
  final int maxOrders;

  /// Try to deliver the queue as one sale. Returns true when it did, in which case
  /// there are no sales left for the drain behind it.
  Future<bool> run() async {
    if (!enabled()) return false;
    // No shift is no key, and a batch with no stable key is the one thing this
    // must never send.
    final uuid = batchUuid();
    if (uuid == null) return false;
    // One row over the bound means there may be more behind it, and a batch built
    // over a window that was cut short is a batch that leaves sales out. Leaving
    // sales out under a key the server has already seen is how a re-cut loses
    // them, so the whole queue is either in view or nothing is merged.
    final pending = await outboxStore.pending(limit: maxOrders + 1);
    if (pending.length > maxOrders) return false;
    final sales = pending.where((e) => e.kind == 'order.push').toList();
    final batch = mergeOrderPushes(sales, batchUuid: uuid).batch;
    if (batch == null) return false;
    // Nothing is marked until the server has it, so a failure anywhere above
    // leaves the night queued rather than half booked and half forgotten.
    await send(batch.uuid, batch.payload);
    for (final id in batch.entryIds) {
      await outboxStore.markSent(id);
    }
    for (final orderUuid in batch.orderUuids) {
      onOrderBooked(orderUuid);
    }
    return true;
  }
}
