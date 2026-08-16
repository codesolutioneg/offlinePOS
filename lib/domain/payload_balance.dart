/// Does a sale payload add up?
///
/// The module books a sale from the lines it is handed and then settles it from
/// the payments it is handed. If those two disagree the sale either fails to book
/// or books for the wrong money, and both of those are takings that never reach
/// the books. So the arithmetic the server will do is written out here, once, and
/// checked before anything leaves the till.
///
/// This works on the payload map rather than on [Order] on purpose. The map is
/// what is actually sent, it is what comes back out of the outbox after a restart,
/// and a bug in building it is exactly the bug this is here to catch.
library;

/// How far apart the two sides may be before the payload is called broken.
///
/// One piastre, the same bar the module holds its own total to. Scaling a line by
/// a discount and a service percentage leaves floating-point dust far below this;
/// anything above it is a real charge that is on one side of the sale and not the
/// other.
const double kPayloadBalanceTolerance = 0.01;

/// What Odoo will total from the `lines` this payload declares.
///
/// Mirrors what the module does with them: each line is quantity times unit price,
/// and each modifier that names a product becomes its own line at that modifier's
/// quantity times the parent's. A modifier with no product is skipped there, so it
/// must contribute nothing here either; the till folds that money into its parent's
/// unit price before sending, which is the same contract from the other end.
double payloadLinesTotal(Map<String, dynamic> payload) {
  var total = 0.0;
  for (final raw in (payload['lines'] as List? ?? const [])) {
    final line = (raw as Map).cast<String, dynamic>();
    final qty = _num(line['quantity']);
    total += qty * _num(line['unit_price']);
    for (final rawMod in (line['modifiers'] as List? ?? const [])) {
      final mod = (rawMod as Map).cast<String, dynamic>();
      if (mod['product_id'] == null) continue;
      total += qty * _num(mod['quantity']) * _num(mod['unit_price']);
    }
  }
  return total;
}

/// The two charges that reach Odoo as fields of their own rather than as lines,
/// for the module to price into the sale it builds.
double payloadPricedExtras(Map<String, dynamic> payload) =>
    _num(payload['delivery_cost']) + _num(payload['tip']);

/// Everything this payload says was sold: its lines plus [payloadPricedExtras].
double payloadDeclaredTotal(Map<String, dynamic> payload) =>
    payloadLinesTotal(payload) + payloadPricedExtras(payload);

/// Everything this payload says was tendered.
double payloadTendered(Map<String, dynamic> payload) => (payload['payments']
        as List? ??
        const [])
    .fold(0.0, (sum, p) => sum + _num(((p as Map).cast<String, dynamic>())['amount']));

/// What the payload declares as tendered, less what it declares as sold.
///
/// Zero when no payments travel: the module then books its own computed total to
/// cash, so the two sides agree by construction and there is nothing to check.
double payloadImbalance(Map<String, dynamic> payload) {
  final payments = payload['payments'] as List? ?? const [];
  if (payments.isEmpty) return 0;
  return payloadTendered(payload) - payloadDeclaredTotal(payload);
}

/// True when the sale this payload declares is the sale it declares was paid for.
bool payloadBalances(Map<String, dynamic> payload) =>
    payloadImbalance(payload).abs() <= kPayloadBalanceTolerance;

/// Why this payload cannot be booked, in the words a human reads off the parked
/// entry, or null when it is fine. Money figures rather than a bare "mismatch":
/// the gap is usually a charge the payload states on one side only, and its size
/// says which one.
String? payloadImbalanceReason(Map<String, dynamic> payload) {
  if (payloadBalances(payload)) return null;
  final gap = payloadImbalance(payload);
  return 'payload does not add up: tendered ${_money(payloadTendered(payload))} '
      'against lines ${_money(payloadLinesTotal(payload))} plus delivery and tip '
      '${_money(payloadPricedExtras(payload))}, a gap of ${_money(gap)}';
}

double _num(Object? v) => v is num ? v.toDouble() : 0.0;

String _money(double v) => v.toStringAsFixed(2);
