import 'order.dart';

/// Sales a full refund in [orders] has taken back, plus those refunds.
///
/// A "Cancel sale" leaves the original check paid and adds a matching negative
/// refund. Flash, the Z, and the Odoo session merge must drop that pair or the
/// books still show money that left the till — and complimentary / officer
/// tenders on the cancelled ticket inflate the consolidated payment lines.
List<Order> withoutFullyCancelled(List<Order> orders) {
  final refundNet = <String, double>{};
  for (final o in orders) {
    final of = o.refundOfUuid;
    if (of == null) continue;
    refundNet[of] = (refundNet[of] ?? 0) + o.total;
  }
  final cancelled = <String>{};
  for (final o in orders) {
    if (o.isRefund) continue;
    // Need a real refund against this ticket — a legitimate zero-total
    // complimentary must not look like a cancel (net 0 with no refund).
    final refunded = refundNet[o.uuid];
    if (refunded == null) continue;
    final net = o.total + refunded;
    if (net.abs() < 0.02) cancelled.add(o.uuid);
  }
  if (cancelled.isEmpty) return orders;
  return [
    for (final o in orders)
      if (!cancelled.contains(o.uuid) &&
          (o.refundOfUuid == null || !cancelled.contains(o.refundOfUuid)))
        o,
  ];
}

/// Paid tickets still owed to the books: drop full cancel pairs and never keep
/// a refund row (refunds are booked by hand in Odoo).
List<Order> salesForOdoo(List<Order> orders) => [
      for (final o in withoutFullyCancelled(orders))
        if (!o.isRefund) o,
    ];
