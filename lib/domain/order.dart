import 'business_day.dart';
import 'identity.dart';

/// Where the sale is served. Drives the sell screen, the kitchen ticket header,
/// and whether delivery details and a delivery charge are collected.
enum OrderType { dineIn, takeaway, delivery }

extension OrderTypeLabel on OrderType {
  String get label => switch (this) {
        OrderType.dineIn => 'Dine-in',
        OrderType.takeaway => 'Takeaway',
        OrderType.delivery => 'Delivery',
      };
}

/// draft: being rung. held: parked on a table/tab, not yet paid. paid: tendered,
/// queued to sync. synced: acknowledged by the server.
enum OrderState { draft, held, paid, synced }

/// A modifier applied to a line, priced at the moment of sale.
///
/// The price is captured here rather than looked up later: a receipt must never
/// change because someone edited the catalogue afterwards.
class OrderModifier {
  OrderModifier({
    required this.modifierId,
    required this.name,
    required this.quantity,
    required this.unitPrice,
    this.productId,
  });

  final int modifierId;
  final String name;
  final double quantity;
  final double unitPrice;

  /// The product behind this modifier, if it is backed by one. The server books a
  /// modifier as its own order line, so without the product id it cannot move stock
  /// or invoice it; a modifier that is purely a label (no product) has none.
  final int? productId;

  double get total => quantity * unitPrice;

  Map<String, dynamic> toMap() => {
        'modifier_id': modifierId,
        'product_id': productId,
        'name': name,
        'quantity': quantity,
        'unit_price': unitPrice,
      };

  factory OrderModifier.fromMap(Map<String, dynamic> m) => OrderModifier(
        modifierId: m['modifier_id'] as int,
        productId: m['product_id'] as int?,
        name: m['name'] as String,
        quantity: (m['quantity'] as num).toDouble(),
        unitPrice: (m['unit_price'] as num).toDouble(),
      );
}

class OrderLine {
  OrderLine({
    String? uuid,
    required this.productId,
    required this.name,
    required this.quantity,
    required this.unitPrice,
    List<OrderModifier>? modifiers,
    this.note,
    this.discountPercent = 0,
    this.categoryId,
    this.printedToKitchen = false,
  })  : uuid = uuid ?? Uuid.v4(),
        modifiers = modifiers ?? [];

  final String uuid;
  final int productId;
  final String name;
  double quantity;
  final double unitPrice;
  final List<OrderModifier> modifiers;

  /// A free-text kitchen note for this line ("no onions", "well done").
  String? note;

  /// A per-line discount, 0-100, distinct from the whole-order discount.
  double discountPercent;

  /// The product's category, kept on the line so a kitchen ticket can be routed
  /// to the right station without a second catalogue lookup at print time.
  final int? categoryId;

  /// Whether this line has already been sent to the kitchen. Lets a re-fire print
  /// only the newly added lines rather than the whole ticket again.
  bool printedToKitchen;

  double get lineDiscountFactor => 1 - (discountPercent.clamp(0, 100) / 100);

  /// Gross of any discount: quantity times unit price plus its modifiers.
  double get gross =>
      quantity * (unitPrice + modifiers.fold(0.0, (s, m) => s + m.total));

  /// What the customer actually pays for this line, after its own discount.
  double get total => gross * lineDiscountFactor;

  Map<String, dynamic> toMap() => {
        'uuid': uuid,
        'product_id': productId,
        'name': name,
        'quantity': quantity,
        'unit_price': unitPrice,
        'modifiers': modifiers.map((m) => m.toMap()).toList(),
        'note': note,
        'discount_percent': discountPercent,
        'category_id': categoryId,
        'printed_to_kitchen': printedToKitchen,
      };

  factory OrderLine.fromMap(Map<String, dynamic> m) => OrderLine(
        uuid: m['uuid'] as String,
        productId: m['product_id'] as int,
        name: m['name'] as String,
        quantity: (m['quantity'] as num).toDouble(),
        unitPrice: (m['unit_price'] as num).toDouble(),
        note: m['note'] as String?,
        discountPercent: (m['discount_percent'] as num?)?.toDouble() ?? 0,
        categoryId: m['category_id'] as int?,
        printedToKitchen: (m['printed_to_kitchen'] as bool?) ?? false,
        modifiers: ((m['modifiers'] as List?) ?? const [])
            .map((e) => OrderModifier.fromMap(e as Map<String, dynamic>))
            .toList(),
      );
}

class Order {
  Order({
    String? uuid,
    required this.deviceId,
    required this.cashierId,
    DateTime? createdAt,
    this.state = OrderState.draft,
    this.type = OrderType.dineIn,
    this.discountPercent = 0,
    this.discountReason,
    this.partnerId,
    this.customerName,
    this.customerPhone,
    this.customerAddress,
    this.tableLabel,
    this.guestCount,
    this.note,
    this.deliveryCost = 0,
    this.tip = 0,
    List<OrderLine>? lines,
    List<OrderPayment>? payments,
  })  : uuid = uuid ?? Uuid.v4(),
        createdAt = createdAt ?? DateTime.now().toUtc(),
        lines = lines ?? [],
        payments = payments ?? [];

  final String uuid;
  final String deviceId;
  final String cashierId;
  final DateTime createdAt;
  OrderState state;
  OrderType type;
  final List<OrderLine> lines;

  /// How the sale was tendered. Empty means the server books it to cash. More than
  /// one entry is a split payment.
  List<OrderPayment> payments;

  /// A whole-order discount, 0-100, and why it was given (for the audit and the
  /// discount report). Applied on top of any per-line discounts when the sale is
  /// sent, so the server books the discounted total.
  double discountPercent;
  String? discountReason;

  /// The Odoo partner this sale is for, and its details. For delivery, the phone
  /// and address are captured on the till since a walk-in partner has none.
  int? partnerId;
  String? customerName;
  String? customerPhone;
  String? customerAddress;

  /// Which table or tab this order is parked on, for dine-in hold/recall. Null for
  /// a straight counter sale.
  String? tableLabel;

  /// Covers, for dine-in. Drives the kitchen ticket and split-by-guest.
  int? guestCount;

  /// A whole-order note for the kitchen ("allergy: nuts", "birthday").
  String? note;

  /// A delivery charge added to the total, kept separate so it reports as delivery
  /// income rather than as a sold item.
  double deliveryCost;

  /// A tip added on top of the sale total.
  double tip;

  /// Set once the backend confirms. Never used as identity.
  int? serverId;

  double get subtotal => lines.fold(0.0, (s, l) => s + l.total);
  double get discountFactor => 1 - (discountPercent.clamp(0, 100) / 100);

  /// What the customer pays: lines (each already net of its own discount), less
  /// the whole-order discount, plus delivery and tip.
  double get total => subtotal * discountFactor + deliveryCost + tip;

  /// The trading day this sale belongs to, which decides the session it lands in
  /// on the server.
  BusinessDay get businessDay => BusinessDay.of(createdAt);

  Map<String, dynamic> toMap() => {
        // The idempotency key. The server must treat a repeat of this uuid as the
        // same sale, because a push can be retried after the server committed but
        // before the acknowledgement was recorded.
        'uuid': uuid,
        'device_id': deviceId,
        // Carried explicitly: with one shared Odoo login every order there is
        // attributed to the same user, so this is the only record of who rang it.
        'cashier_id': cashierId,
        // The moment of sale, not the moment of sync. Without it a week of offline
        // orders all post on the day the line came back and every daily report is
        // wrong.
        'created_at': createdAt.toIso8601String(),
        'business_date': businessDay.key,
        'state': state.name,
        'order_type': type.name,
        'server_id': serverId,
        'discount_percent': discountPercent,
        'discount_reason': discountReason,
        'partner_id': partnerId,
        'customer_name': customerName,
        'customer_phone': customerPhone,
        'customer_address': customerAddress,
        'table_label': tableLabel,
        'guest_count': guestCount,
        'note': note,
        'delivery_cost': deliveryCost,
        'tip': tip,
        'lines': lines.map((l) => l.toMap()).toList(),
        'payments': payments.map((p) => p.toMap()).toList(),
      };

  /// The payload sent to the server: like [toMap] but with both the per-line and
  /// the whole-order discount folded into each line price, so Odoo (which totals
  /// from the line prices) books the discounted amount. [toMap] itself stays raw,
  /// so a draft restored from disk is not discounted twice.
  Map<String, dynamic> toServerPayload() {
    final f = discountFactor;
    final m = toMap();
    // The discount is now baked into the prices below, so the percentage fields are
    // zeroed on the wire. Leaving them set would let a server that also reads them
    // discount an already-discounted price a second time.
    m['discount_percent'] = 0;
    m['lines'] = lines.map((l) {
      final lf = l.lineDiscountFactor * f;
      final lm = l.toMap();
      lm['unit_price'] = l.unitPrice * lf;
      lm['discount_percent'] = 0;
      lm['modifiers'] = l.modifiers.map((mod) {
        final mm = mod.toMap();
        mm['unit_price'] = mod.unitPrice * lf;
        return mm;
      }).toList();
      return lm;
    }).toList();
    return m;
  }

  factory Order.fromMap(Map<String, dynamic> m) => Order(
        uuid: m['uuid'] as String,
        deviceId: m['device_id'] as String,
        cashierId: m['cashier_id'] as String,
        createdAt: DateTime.parse(m['created_at'] as String),
        state: OrderState.values.byName(m['state'] as String),
        type: OrderType.values
            .byName((m['order_type'] as String?) ?? OrderType.dineIn.name),
        discountPercent: (m['discount_percent'] as num?)?.toDouble() ?? 0,
        discountReason: m['discount_reason'] as String?,
        partnerId: m['partner_id'] as int?,
        customerName: m['customer_name'] as String?,
        customerPhone: m['customer_phone'] as String?,
        customerAddress: m['customer_address'] as String?,
        tableLabel: m['table_label'] as String?,
        guestCount: m['guest_count'] as int?,
        note: m['note'] as String?,
        deliveryCost: (m['delivery_cost'] as num?)?.toDouble() ?? 0,
        tip: (m['tip'] as num?)?.toDouble() ?? 0,
        lines: ((m['lines'] as List?) ?? const [])
            .map((e) => OrderLine.fromMap(e as Map<String, dynamic>))
            .toList(),
        payments: ((m['payments'] as List?) ?? const [])
            .map((e) => OrderPayment.fromMap((e as Map).cast<String, dynamic>()))
            .toList(),
      )..serverId = m['server_id'] as int?;
}

/// One tender against a sale: which Odoo payment method, how much, and any tip
/// taken on that tender. Several of these on one order is a split payment.
class OrderPayment {
  const OrderPayment({required this.methodId, required this.amount, this.label});
  final int methodId;
  final double amount;

  /// The method's display name, kept so the receipt and reports can show "Card"
  /// without a second catalogue lookup.
  final String? label;

  Map<String, dynamic> toMap() =>
      {'method_id': methodId, 'amount': amount, 'label': label};
  factory OrderPayment.fromMap(Map<String, dynamic> m) => OrderPayment(
        methodId: m['method_id'] as int,
        amount: (m['amount'] as num).toDouble(),
        label: m['label'] as String?,
      );
}
