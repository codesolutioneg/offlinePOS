import 'business_day.dart';
import 'identity.dart';

/// Where the sale is served. Drives the sell screen, the kitchen ticket header,
/// and whether delivery details and a delivery charge are collected.
///
/// [toGo] is food eaten off the premises that is still rung in the room: the guests
/// sit at a table while it is packed, so it occupies the floor like a dine-in but
/// is bagged like a takeaway. It is its own type rather than a flag on takeaway
/// because the shop prices it on its own line of the tax and service matrices.
enum OrderType { dineIn, takeaway, toGo, delivery }

extension OrderTypeLabel on OrderType {
  String get label => switch (this) {
        OrderType.dineIn => 'Dine-in',
        OrderType.takeaway => 'Takeaway',
        OrderType.toGo => 'To go',
        OrderType.delivery => 'Delivery',
      };

  /// Whether this kind of sale can sit at a table on the floor plan. Mandatory for
  /// a dine-in, optional for a to-go, meaningless for the two that leave the room.
  bool get seatsAtTable => this == OrderType.dineIn || this == OrderType.toGo;

  /// What the server is told this sale was. The module books `order_type` from a
  /// fixed vocabulary, and to-go is a distinction the shop makes on its own floor:
  /// it goes over the wire as the takeaway it is, and the difference stays here,
  /// on the till that prints it and reports on it.
  String get wireName =>
      this == OrderType.toGo ? OrderType.takeaway.name : name;
}

/// draft: being rung. held: parked on a table/tab, not yet paid. paid: tendered,
/// queued to sync. synced: acknowledged by the server.
enum OrderState { draft, held, paid, synced }

/// Where a ticket is in the kitchen, for the kitchen display board.
enum KitchenStatus { pending, preparing, ready, served }

extension KitchenStatusLabel on KitchenStatus {
  String get label => switch (this) {
        KitchenStatus.pending => 'New',
        KitchenStatus.preparing => 'Preparing',
        KitchenStatus.ready => 'Ready',
        KitchenStatus.served => 'Served',
      };
}

/// The percentage that takes [amount] of money off [base].
///
/// A cashier who is told "give them 50 off" thinks in money, but a discount lives on
/// an order as a percentage: that is what the receipt prints, what the reports total,
/// and what [Order.toServerPayload] folds into the line prices. Converting here, at
/// the moment it is applied, is what lets an amount be typed without a second concept
/// travelling through all of that. A base of zero (an empty bill) gives nothing away.
double discountPercentForAmount(double amount, double base) {
  if (amount <= 0 || base <= 0) return 0;
  return (amount / base * 100).clamp(0, 100).toDouble();
}

/// How a discount is written on the sale the server is handed.
///
/// Published from settings the way the trading-day rule is, because every order,
/// wherever it was built (a sale, a split check, a refund), has to write it the
/// same way.
class DiscountBooking {
  /// The Odoo product a discount is booked against, or null.
  ///
  /// Null keeps the discount inside the line prices: the money and the tax are
  /// right, but Odoo is handed a cheaper item rather than a discount, so nothing
  /// there can report on it. Naming a product instead sends the full menu prices
  /// and one negative line, which is how Odoo writes a discount itself and the only
  /// way it shows as one without the module learning a new field.
  ///
  /// It must be a **service** product: a negative line on a storable one would put
  /// stock back on the shelf.
  static int? productId;
}

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
    double taxRate = 0,
    double? baseTaxRate,
    this.printedToKitchen = false,
    this.seat,
    this.fireAt,
    List<String>? firedStations,
  })  : uuid = uuid ?? Uuid.v4(),
        // Not an initializing formal because baseTaxRate defaults to this value.
        // ignore: prefer_initializing_formals
        taxRate = taxRate,
        // The product's own rate, kept so the tax matrix can be undone: switching to
        // an order type with no override restores this instead of leaving the last
        // override stuck on the line.
        baseTaxRate = baseTaxRate ?? taxRate,
        modifiers = modifiers ?? [],
        firedStations = firedStations ?? [];

  final String uuid;
  final int productId;
  final String name;
  double quantity;

  /// What one of these costs, captured from the catalogue when the line was rung.
  // Mutable only so a manager-gated, audited price override can restate it on the
  // line; nothing else writes it, and the captured value is still what a later
  // catalogue change can never touch.
  double unitPrice;
  final List<OrderModifier> modifiers;

  /// A free-text kitchen note for this line ("no onions", "well done").
  String? note;

  /// A per-line discount, 0-100, distinct from the whole-order discount.
  double discountPercent;

  /// The product's category, kept on the line so a kitchen ticket can be routed
  /// to the right station without a second catalogue lookup at print time.
  final int? categoryId;

  /// The line's tax rate as a percent (e.g. 14 for 14%), captured from the product
  /// at the moment of sale. Prices are treated as tax-inclusive, so this is used
  /// only to show the tax component; the amount the customer pays is unchanged.
  // Mutable so the category/order-type tax matrix can override the product's rate
  // when the line is added or the order type changes.
  double taxRate;

  /// The product's original tax rate, captured at sale. [taxRate] may be overridden
  /// by the category/order-type matrix; this is what it falls back to when no
  /// override applies to the current order type.
  final double baseTaxRate;

  /// Whether this line has already been sent to the kitchen. Lets a re-fire print
  /// only the newly added lines rather than the whole ticket again.
  bool printedToKitchen;

  /// The station name(s) this line's ticket was actually sent to, recorded at fire
  /// time so a later void reaches the same printer even if routing changed since.
  final List<String> firedStations;

  /// When this line should be fired to the kitchen. Null fires immediately with the
  /// rest of the order; a future time holds it back for course firing ("fire the
  /// mains 15 minutes after the starters"). Cleared once fired.
  DateTime? fireAt;

  /// A course-fired line still waiting for its time.
  bool get isTimed => fireAt != null && !printedToKitchen;

  /// Whether this line is due to fire now (no timer, or the timer has elapsed).
  bool dueAt(DateTime now) => fireAt == null || !fireAt!.isAfter(now);

  /// Which guest/seat this line belongs to, for dine-in bill splitting (1-based).
  /// Null means unassigned (shared / not yet split). Drives split-by-guest and the
  /// per-seat kitchen ticket.
  int? seat;

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
        'tax_rate': taxRate,
        'base_tax_rate': baseTaxRate,
        'printed_to_kitchen': printedToKitchen,
        'seat': seat,
        'fired_stations': firedStations,
        'fire_at': fireAt?.toIso8601String(),
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
        taxRate: (m['tax_rate'] as num?)?.toDouble() ?? 0,
        baseTaxRate: (m['base_tax_rate'] as num?)?.toDouble(),
        printedToKitchen: (m['printed_to_kitchen'] as bool?) ?? false,
        seat: m['seat'] as int?,
        firedStations:
            ((m['fired_stations'] as List?) ?? const []).map((e) => e.toString()).toList(),
        fireAt: m['fire_at'] == null ? null : DateTime.parse(m['fire_at'] as String),
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
    this.deliveryChannel,
    this.companyOrderNo,
    this.driverName,
    this.serviceChargePercent = 0,
    this.tip = 0,
    this.kitchenStatus = KitchenStatus.pending,
    this.refundOfUuid,
    int? businessDayCutoverHour,
    this.orderNo,
    List<OrderLine>? lines,
    List<OrderPayment>? payments,
  })  : uuid = uuid ?? Uuid.v4(),
        createdAt = createdAt ?? DateTime.now().toUtc(),
        businessDayCutoverHour =
            businessDayCutoverHour ?? BusinessDay.shopCutoverHour,
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

  /// Which channel this delivery came through ("Talabat", "Phone"), the number that
  /// channel calls the order, and who is carrying it.
  ///
  /// All three are local to the till and stripped from the server payload. The wire
  /// contract is fixed: the sale is a delivery, and who it is for travels as the
  /// partner. An aggregator's own reference and the name of the driver are how the
  /// shop finds the order on its own floor, and the server has nowhere to put them.
  String? deliveryChannel;
  String? companyOrderNo;
  String? driverName;

  /// The service percentage this bill carries, stamped when the order is created and
  /// re-stamped when its type changes, never read from settings at total time: a bill
  /// parked on a table must not change price because a manager edited the setting while
  /// the guests were still eating.
  double serviceChargePercent;

  /// A tip added on top of the sale total.
  double tip;

  /// Where this order's ticket is in the kitchen, for the KDS board.
  KitchenStatus kitchenStatus;

  /// When set, this order reverses an earlier sale (a refund/return). Its lines
  /// carry negative quantities, so it books a credit against the original.
  String? refundOfUuid;

  bool get isRefund => refundOfUuid != null;

  /// The number a human calls this sale: what the cashier shouts, the customer
  /// quotes on the phone and the kitchen writes on the pass. Stamped once, when the
  /// order is parked or paid, and never rewritten.
  ///
  /// Local to the till. It is stripped from the server payload, because the server
  /// numbers its own documents and a till counter arriving there would be a second
  /// sequence claiming to be the first.
  String? orderNo;

  /// What to print or show as this order's reference: its human number once it has
  /// one, and the tail of the uuid before that (a draft being rung has no number
  /// yet, and a slip still has to be identifiable).
  String get displayNo =>
      orderNo ?? uuid.replaceAll('-', '').substring(0, 6).toUpperCase();

  /// Cash the customer handed over, when it exceeds what was due. Kept only so the
  /// receipt can print the change; it is NOT the amount booked. The payment stores
  /// the settled amount (what the sale was worth), so the drawer, the payment mix,
  /// and the server all see revenue rather than the tendered note plus its change.
  double? cashReceived;

  /// Set once the backend confirms. Never used as identity.
  int? serverId;

  /// True once this sale was reopened after payment and rung again. Local only:
  /// it marks the corrected receipt so the customer can tell which of two slips
  /// stands, and it is stripped from the server payload, which carries one sale
  /// under one uuid either way.
  bool amended = false;

  double get subtotal => lines.fold(0.0, (s, l) => s + l.total);
  double get discountFactor => 1 - (discountPercent.clamp(0, 100) / 100);

  /// What the service charge is taken on: the food after every discount. Delivery and
  /// tip stay outside it, since neither is table service.
  double get serviceChargeBase => subtotal * discountFactor;

  /// The service money on this bill, from the percentage stamped on it.
  double get serviceCharge =>
      serviceChargeBase * serviceChargePercent.clamp(0, 100) / 100;

  /// One plus the charge, for callers that scale a part of the bill (a split check, a
  /// refund) by the same service the customer paid on it.
  double get serviceChargeFactor => 1 + serviceChargePercent.clamp(0, 100) / 100;

  /// What the customer pays: lines (each already net of its own discount), less
  /// the whole-order discount, plus service, delivery and tip.
  double get total =>
      subtotal * discountFactor + serviceCharge + deliveryCost + tip;

  /// Money already tendered against this order. On a normal sale this equals the
  /// total; on an even/part-paid open tab it is the sum of the shares taken so far.
  double get amountPaid => payments.fold(0.0, (s, p) => s + p.amount);

  /// What is still owed. Zero (or below) means the order is fully settled.
  double get balance => total - amountPaid;

  /// The tax already contained in the line prices (prices are tax-inclusive), after
  /// the whole-order discount. Informational: it does not change [total]. The server
  /// remains the source of truth for the tax actually booked.
  double get taxTotal {
    var t = 0.0;
    // The service charge rides in the line prices on the wire, so the server taxes it
    // at each item's own rate. Scaling by it here keeps the tax shown on the slip equal
    // to the tax that gets booked.
    final s = serviceChargeFactor;
    for (final l in lines) {
      if (l.taxRate <= 0) continue;
      final net = l.total * discountFactor * s;
      t += net - net / (1 + l.taxRate / 100);
    }
    return t;
  }

  /// The hour the trading day this bill belongs to rolls over, stamped from the
  /// shop's rule when the order is created. Local only: the server is handed the
  /// business date it produced, and has no use for the rule behind it.
  ///
  /// Stamped rather than read live so a manager moving the cutover cannot move a
  /// sale that has already been counted, printed or pushed onto another day.
  final int businessDayCutoverHour;

  /// The trading day this sale belongs to, which decides the session it lands in
  /// on the server.
  BusinessDay get businessDay =>
      BusinessDay.of(createdAt, cutoverHour: businessDayCutoverHour);

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
        'business_day_cutover_hour': businessDayCutoverHour,
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
        'delivery_channel': deliveryChannel,
        'company_order_no': companyOrderNo,
        'driver_name': driverName,
        'service_charge_percent': serviceChargePercent,
        'tip': tip,
        'kitchen_status': kitchenStatus.name,
        'refund_of_uuid': refundOfUuid,
        'order_no': orderNo,
        'cash_received': cashReceived,
        'amended': amended,
        'lines': lines.map((l) => l.toMap()).toList(),
        'payments': payments.map((p) => p.toMap()).toList(),
      };

  /// The money this sale was discounted by, per-line discounts and the whole-order
  /// one together, on the same scale as the prices that go on the wire.
  ///
  /// Negative on a refund, where the lines are negative and the discount is being
  /// handed back rather than given.
  double get discountMoney {
    final s = serviceChargeFactor;
    final f = discountFactor;
    var off = 0.0;
    // What each line was worth less what it is worth now, rather than a percentage
    // of the whole: subtracting the two figures the lines are actually sent at is
    // what keeps the discount line exact to the cent instead of a rounding away.
    for (final l in lines) {
      final gross = l.gross * s;
      off += gross - gross * l.lineDiscountFactor * f;
    }
    return off;
  }

  /// The payload sent to the server: like [toMap] but with the per-line discount, the
  /// whole-order discount and the service charge folded into each line price, so Odoo
  /// (which totals from the line prices) books what the customer actually paid.
  /// [toMap] itself stays raw, so a draft restored from disk is not adjusted twice.
  ///
  /// When the shop has named a discount product the discount comes back out of the
  /// prices and travels as its own negative line instead, so Odoo shows the menu
  /// price on every item and the discount as a discount. The sale totals the same
  /// either way; only how it reads on the Odoo document changes.
  Map<String, dynamic> toServerPayload() {
    final f = discountFactor;
    // The service charge is a percentage of the discounted food, so scaling every line
    // by it books the same total the till printed and taxes the service at each item's
    // own rate. It travels in the prices rather than as a field of its own because the
    // module books lines, and the wire contract is fixed.
    final s = serviceChargeFactor;
    final m = toMap();
    // Which of the two ways this sale states its discount. Null is the old one, and
    // the only one a shop that has named no product can have.
    final discountProduct = DiscountBooking.productId;
    // The discount is now baked into the prices below, so the percentage fields are
    // zeroed on the wire. Leaving them set would let a server that also reads them
    // discount an already-discounted price a second time.
    m['discount_percent'] = 0;
    // What was taken off, in money, and whether the prices already have it. Without
    // these the payload says nothing about a discount at all: the prices are simply
    // lower, so nothing on the Odoo side can report on one. Stated rather than
    // re-applied, and the flag is what makes double-applying impossible.
    m['discount_amount'] = discountMoney;
    m['prices_include_discount'] = discountProduct == null;
    // Local-only, and for the same reason: the charge is already inside the prices, and
    // a field the module does not read could only ever be billed twice.
    m.remove('service_charge_percent');
    // Whether the till corrected this sale before sending it is the till's own
    // business: the server is handed one sale under one uuid either way.
    m.remove('amended');
    // The trading day is already on the wire as business_date. The hour that
    // produced it is a shop rule the server neither reads nor needs.
    m.remove('business_day_cutover_hour');
    // The human number is the till's counter, for the people in the shop. The server
    // numbers its own documents, and the uuid is what identifies this sale there.
    m.remove('order_no');
    // A to-go sale books as the takeaway it is. Sending a value the module has
    // never seen would reject a sale over a label nobody there reads.
    m['order_type'] = type.wireName;
    // How the shop runs its own deliveries: which app the order came through, that
    // app's own reference for it, and who drove it. The module books a sale, not a
    // dispatch record, so none of this has a field to land in.
    m.remove('delivery_channel');
    m.remove('company_order_no');
    m.remove('driver_name');
    // A locally-created customer has a synthetic negative id, not an Odoo partner.
    // Never send it as partner_id (it would fail the foreign key); the name and
    // phone still travel so the server can match or create the partner itself.
    if (partnerId != null && partnerId! < 0) m['partner_id'] = null;
    m['lines'] = lines.map((l) {
      // With a discount product the prices stay whole and the discount leaves as a
      // line of its own; without one it is folded in here as it always was.
      final lf = discountProduct == null ? l.lineDiscountFactor * f * s : s;
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
    // One line for every discount on the bill, so the sale still totals what the
    // customer paid. Skipped when nothing was given away, and never rounded to
    // nothing: a fraction of a piastre is not a discount.
    if (discountProduct != null && discountMoney.abs() > 0.005) {
      (m['lines'] as List).add({
        'product_id': discountProduct,
        'name': 'Discount',
        'quantity': 1,
        'unit_price': -discountMoney,
        'discount_percent': 0,
        'modifiers': const [],
      });
    }
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
        deliveryChannel: m['delivery_channel'] as String?,
        companyOrderNo: m['company_order_no'] as String?,
        driverName: m['driver_name'] as String?,
        serviceChargePercent:
            (m['service_charge_percent'] as num?)?.toDouble() ?? 0,
        tip: (m['tip'] as num?)?.toDouble() ?? 0,
        kitchenStatus: KitchenStatus.values
            .byName((m['kitchen_status'] as String?) ?? KitchenStatus.pending.name),
        refundOfUuid: m['refund_of_uuid'] as String?,
        // An order saved before the cutover was configurable was rung under the old
        // fixed rule, so it keeps that one rather than adopting today's setting and
        // moving itself to another day.
        businessDayCutoverHour: (m['business_day_cutover_hour'] as num?)?.toInt() ??
            BusinessDay.defaultCutoverHour,
        orderNo: m['order_no'] as String?,
        lines: ((m['lines'] as List?) ?? const [])
            .map((e) => OrderLine.fromMap(e as Map<String, dynamic>))
            .toList(),
        payments: ((m['payments'] as List?) ?? const [])
            .map((e) => OrderPayment.fromMap((e as Map).cast<String, dynamic>()))
            .toList(),
      )
        ..serverId = m['server_id'] as int?
        ..cashReceived = (m['cash_received'] as num?)?.toDouble()
        ..amended = (m['amended'] as bool?) ?? false;
}

/// The label an on-account tender carries, and the one thing that says a sale was
/// left on a customer's tab rather than settled at the counter.
///
/// A label rather than a field on the order: the money is a tender like any other,
/// it books through the payment method the shop nominated, and reports that read
/// tenders (the payment mix, the receivables list) all see it without a second
/// concept travelling through the payload.
const String kOnAccountLabel = 'On account';

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
