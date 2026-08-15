/// The three lists a delivery shop keeps on the till: where it drives to, who
/// sends it the order, and who carries the bag.
///
/// All of it is local. None of it is on the wire: the server is told the sale is a
/// delivery and who the customer is, and the rest is how the shop runs its own
/// floor. Nothing here carries a timer or a dispatch state, which is deliberate:
/// this is the slice a cashier needs, not a dispatch system.
library;

/// A named area with the charge the shop bills for driving to it.
class DeliveryZone {
  const DeliveryZone({required this.id, required this.name, required this.fee});

  final String id;
  final String name;

  /// What the delivery costs in this zone. The cashier can still type over it on
  /// the order: a zone is a preset, not a rule.
  final double fee;
}

/// Where the order came from: the shop's own phone, or an aggregator app.
class DeliveryChannel {
  const DeliveryChannel({required this.id, required this.name, this.partnerId});

  final String id;
  final String name;

  /// The Odoo partner the aggregator is booked against, when the shop invoices the
  /// company rather than the guest. Null for a channel that is just a label.
  final int? partnerId;
}

/// Someone who takes the bag out. Name and phone is the whole model: the till has
/// to be able to say who has the order and ring them, and nothing more.
class Driver {
  const Driver({
    required this.id,
    required this.name,
    this.phone,
    this.active = true,
  });

  final String id;
  final String name;
  final String? phone;

  /// A driver who has left stays on file (old orders still name them) but drops
  /// out of the picker.
  final bool active;
}
