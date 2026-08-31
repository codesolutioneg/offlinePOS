import '../../domain/payload_balance.dart';
import 'outbox.dart';

/// One payload holding a whole shift's sales, for the shop that wants its night in
/// the books as a single sales order rather than three hundred.
///
/// Off unless a manager turns it on, and it needs a change in jouma before it is
/// safe to turn on: see the patch proposal in docs/ODOO_SYNC.md. What is built
/// here is the till half, so the day the module accepts it there is a switch to
/// throw rather than a release to write.
///
/// Three things are deliberately not traded away, because they are the three
/// Dishflow gave up to get the same behaviour out of its own endpoint:
///
/// * **The idempotency key.** The merged payload has a uuid of its own, derived
///   from the shift, so a retry after a timeout returns the same night rather than
///   booking it twice. Dishflow strips its key and recovers by hunting the last
///   confirmed orders for a matching total.
/// * **The per-ticket detail.** Every line keeps the uuid of the sale it came from
///   and every ticket keeps its own header, so who rang what, when, and on which
///   table survives the merge. Dishflow aggregates the lines by product, and that
///   detail is gone.
/// * **The arithmetic.** The merged payload adds up the same way a single sale
///   does: what it says was tendered equals what it says was sold.
class MergedBatch {
  const MergedBatch({
    required this.uuid,
    required this.payload,
    required this.entryIds,
    required this.orderUuids,
  });

  /// The batch's own idempotency key.
  final String uuid;

  /// What goes on the wire.
  final Map<String, dynamic> payload;

  /// The outbox rows this batch stands for, marked sent together once the server
  /// has it and left untouched otherwise.
  final List<int> entryIds;

  /// The sales inside it, so each can be marked synced on the till.
  final List<String> orderUuids;
}

/// Why a batch was left to go out one sale at a time. Not a failure: the per-sale
/// push is the safe path and is always available, so anything that would make a
/// merge lossy falls back to it rather than being forced through.
class BatchNotMerged {
  const BatchNotMerged(this.reason);
  final String reason;
}

/// The result of asking for a merge: one of the two above.
class MergeOutcome {
  const MergeOutcome.merged(MergedBatch this.batch) : notMerged = null;
  const MergeOutcome.skipped(BatchNotMerged this.notMerged) : batch = null;
  final MergedBatch? batch;
  final BatchNotMerged? notMerged;
}

/// Fold [entries] into one payload keyed on [batchUuid].
///
/// [batchUuid] is the shift's own uuid. A shift is the natural batch and it
/// already carries a uuid nothing else consumes, so the merged sale gets a key
/// that is stable across every retry of the same close.
MergeOutcome mergeOrderPushes(
  List<OutboxEntry> entries, {
  required String batchUuid,
}) {
  final sales = <OutboxEntry>[];
  for (final e in entries) {
    if (e.kind != 'order.push') continue;
    // A credit cannot be a line on somebody else's sale, and an unpaid ticket
    // cannot settle inside a merged payment. Both go out on their own, which is
    // also what Dishflow does with its on-account sales.
    if (e.payload['refund_of_uuid'] != null) continue;
    sales.add(e);
  }
  if (sales.length < 2) {
    return const MergeOutcome.skipped(
        BatchNotMerged('fewer than two sales to merge'));
  }
  // Whether the prices already have the discount in them is a shop setting read
  // when each sale was turned into a payload, so a batch spanning a change to it
  // holds both answers and one merged discount figure could only be read wrong.
  final statesDiscount =
      sales.map((e) => e.payload['prices_include_discount']).toSet();
  if (statesDiscount.length > 1) {
    return const MergeOutcome.skipped(BatchNotMerged(
        'the batch states its discount two different ways'));
  }

  final lines = <Map<String, dynamic>>[];
  final orders = <Map<String, dynamic>>[];
  // Keyed on the method and the journal together: the same method can book to
  // different journals across a night, and those are different money.
  final tenders = <(int, int?), Map<String, dynamic>>{};
  var delivery = 0.0;
  var tip = 0.0;
  var discount = 0.0;
  var amountTotal = 0.0;
  DateTime? earliest;
  final businessDates = <String>{};

  for (final e in sales) {
    final p = e.payload;
    final uuid = p['uuid']?.toString() ?? e.payloadUuid;
    for (final raw in (p['lines'] as List? ?? const [])) {
      final line = (raw as Map).cast<String, dynamic>();
      // Tagged rather than aggregated. One merged document still has to be able to
      // say which sale each line was rung on, or the merge has thrown away the
      // only record of it: with one shared Odoo login the till payload is where
      // that lives.
      lines.add({...line, 'order_uuid': uuid});
    }
    for (final raw in (p['payments'] as List? ?? const [])) {
      final pay = (raw as Map).cast<String, dynamic>();
      final method = (pay['method_id'] as num?)?.toInt();
      if (method == null) continue;
      final journal = (pay['journal_id'] as num?)?.toInt();
      // Grouped by the journal as well as the method, and the journal carried
      // through. Summing on the method alone would fold two tenders that book to
      // different journals into one figure, and the merged night would then settle
      // into whichever the server resolved rather than the two the till took the
      // money on.
      final at = tenders.putIfAbsent(
          (method, journal),
          () => {
                'method_id': method,
                'journal_id': ?journal,
                'amount': 0.0,
                'label': pay['label'],
              });
      at['amount'] = (at['amount'] as double) + _num(pay['amount']);
    }
    delivery += _num(p['delivery_cost']);
    tip += _num(p['tip']);
    discount += _num(p['discount_amount']);
    amountTotal += _num(p['amount_total']);
    final at = DateTime.tryParse(p['created_at']?.toString() ?? '');
    if (at != null && (earliest == null || at.isBefore(earliest))) earliest = at;
    final day = p['business_date']?.toString();
    if (day != null) businessDates.add(day);
    // The ticket's own header, without its lines: those are above, carrying this
    // uuid, so nothing is duplicated and nothing is lost.
    orders.add({
      for (final k in p.keys)
        if (k != 'lines') k: p[k],
    });
  }

  final payload = <String, dynamic>{
    // The batch's key. Everything about not booking the night twice hangs on the
    // server treating a repeat of this as the same batch.
    'uuid': batchUuid,
    'batch': true,
    'order_count': sales.length,
    if (earliest != null) 'created_at': earliest.toIso8601String(),
    // One merged document can only carry one trading day. When the batch spans
    // more than one it is left off and each ticket keeps its own below, rather
    // than posting a week onto whichever day happened to be first.
    if (businessDates.length == 1) 'business_date': businessDates.single,
    'delivery_cost': delivery,
    'tip': tip,
    'discount_amount': discount,
    'prices_include_discount': statesDiscount.single,
    'amount_total': amountTotal,
    'lines': lines,
    'payments': tenders.values.toList(),
    // Everything a single-sale payload carries, per ticket, so the module can
    // stay idempotent per ticket, refuse per ticket, and keep who rang what.
    'orders': orders,
  };

  // The merged sale has to add up for the same reason a single one does. Each
  // member already did, so this can only fail if the merge itself dropped
  // something, which is precisely when it must not be sent.
  final imbalance = payloadImbalanceReason(payload);
  if (imbalance != null) return MergeOutcome.skipped(BatchNotMerged(imbalance));

  return MergeOutcome.merged(MergedBatch(
    uuid: batchUuid,
    payload: payload,
    entryIds: [for (final e in sales) e.id],
    orderUuids: [
      for (final e in sales) e.payload['uuid']?.toString() ?? e.payloadUuid
    ],
  ));
}

double _num(Object? v) => v is num ? v.toDouble() : 0.0;
