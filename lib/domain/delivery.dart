/// The three lists a delivery shop keeps on the till: where it drives to, who
/// sends it the order, and who carries the bag.
///
/// Zones / channels / drivers live on the device. Dishflow mirror carries
/// driver id/name/phone, fees, and delivery_status so the rider app and
/// «حساب الطيار» reports match Dishflow.
library;

/// Ops lifecycle on a delivery bag (Dishflow `delivery_status`). Separate from
/// sale state: financial close does not wait for `delivered`.
enum DeliveryStatus {
  received,
  sent,
  onTheWay,
  delivered;

  String get label => switch (this) {
        received => 'Received',
        sent => 'Assigned',
        onTheWay => 'On the way',
        delivered => 'Delivered',
      };

  /// Wire / Firestore value Dishflow already reads.
  String get wireName => switch (this) {
        received => 'received',
        sent => 'sent',
        onTheWay => 'on_the_way',
        delivered => 'delivered',
      };

  static DeliveryStatus parse(String? raw) {
    final v = (raw ?? '').trim().toLowerCase();
    return switch (v) {
      'sent' || 'assigned' => sent,
      'on_the_way' || 'on the way' || 'ontheway' => onTheWay,
      'delivered' || 'done' || 'completed' => delivered,
      _ => received,
    };
  }
}

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

/// Someone who takes the bag out. Id + name + phone: assign stamps all three on
/// the sale so settlement reports and the rider app can join on `driver_id`.
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

  @override
  bool operator ==(Object other) =>
      other is Driver && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
