import '../core/audit/audit_log.dart';
import '../core/db/catalogue_store.dart';
import '../core/db/order_store.dart';
import '../core/sync/outbox.dart';
import '../domain/catalogue.dart';
import '../domain/order.dart';

/// The live selling state for one cashier on one till.
///
/// Deliberately synchronous. Every operation here is a local read or write, so a tap
/// never awaits anything: that is the whole reason this app exists.
class PosSession {
  PosSession({
    required this.catalogue,
    required this.orders,
    required this.outbox,
    required this.audit,
    required this.deviceId,
    required this.cashierId,
  });

  final CatalogueStore catalogue;
  final OrderStore orders;
  final Outbox outbox;
  final AuditLog audit;
  final String deviceId;
  final String cashierId;

  Order? _current;

  /// The order being built. Restored from disk if one was left unfinished, which is
  /// what gives a cashier their work back after a crash or a closed window.
  Order get current {
    _current ??= orders.drafts().firstOrNull ??
        Order(deviceId: deviceId, cashierId: cashierId);
    return _current!;
  }

  bool get hasLines => current.lines.isNotEmpty;
  double get total => current.total;

  /// How many orders are parked on tables/tabs right now.
  int get heldCount => orders.held().length;

  /// Add a product, applying chosen modifiers. Persisted immediately.
  void addProduct(Product product,
      {List<ChosenModifier> chosen = const [], double qty = 1}) {
    final line = OrderLine(
      productId: product.id,
      name: product.name,
      quantity: qty,
      unitPrice: product.price,
      categoryId: product.categoryId,
      modifiers: [
        for (final c in chosen)
          OrderModifier(
            modifierId: c.modifier.id,
            productId: c.modifier.productId,
            name: c.modifier.name,
            quantity: c.quantity.toDouble(),
            // Priced against the parent now, so a later catalogue change cannot
            // rewrite what the customer was charged.
            unitPrice: c.modifier.priceFor(product.price),
          ),
      ],
    );
    current.lines.add(line);
    orders.save(current);
  }

  /// Remove a line the cashier is still building (no reason needed pre-fire).
  void removeLine(String lineUuid) {
    current.lines.removeWhere((l) => l.uuid == lineUuid);
    orders.save(current);
  }

  /// Void a line with a reason. Returns the removed line so a deletion slip can be
  /// printed to the kitchen if it had already been fired. The reason is recorded
  /// in the audit trail, which is jouma's deleted-lines parity.
  OrderLine? voidLine(String lineUuid, String reason) {
    final idx = current.lines.indexWhere((l) => l.uuid == lineUuid);
    if (idx < 0) return null;
    final line = current.lines.removeAt(idx);
    orders.save(current);
    audit.record(cashierId, 'line.voided',
        detail: '${current.uuid}|${line.name} x${line.quantity}|$reason');
    return line;
  }

  void setQuantity(String lineUuid, double qty) {
    if (qty <= 0) return removeLine(lineUuid);
    final line = current.lines.firstWhere((l) => l.uuid == lineUuid);
    line.quantity = qty;
    orders.save(current);
  }

  /// A per-line discount (0-100%) and a kitchen note on a line.
  void setLineDiscount(String lineUuid, double percent) {
    current.lines.firstWhere((l) => l.uuid == lineUuid).discountPercent =
        percent.clamp(0, 100).toDouble();
    orders.save(current);
  }

  void setLineNote(String lineUuid, String? note) {
    current.lines.firstWhere((l) => l.uuid == lineUuid).note =
        (note == null || note.trim().isEmpty) ? null : note.trim();
    orders.save(current);
  }

  void clear() {
    final order = current;
    order.lines.clear();
    order.discountPercent = 0;
    order.discountReason = null;
    order.partnerId = null;
    order.customerName = null;
    order.customerPhone = null;
    order.customerAddress = null;
    order.tableLabel = null;
    order.guestCount = null;
    order.note = null;
    order.deliveryCost = 0;
    order.tip = 0;
    orders.save(order);
  }

  /// Apply a whole-order discount (0-100%) with an optional reason.
  void setDiscount(double percent, {String? reason}) {
    current.discountPercent = percent.clamp(0, 100).toDouble();
    current.discountReason = reason;
    orders.save(current);
  }

  /// Set the order type. Clears delivery details when switching away from delivery.
  void setOrderType(OrderType type) {
    current.type = type;
    if (type != OrderType.delivery) {
      current.deliveryCost = 0;
      current.customerAddress = null;
    }
    orders.save(current);
  }

  void setGuestCount(int? guests) {
    current.guestCount = (guests != null && guests > 0) ? guests : null;
    orders.save(current);
  }

  void setTable(String? label) {
    current.tableLabel = (label == null || label.trim().isEmpty) ? null : label.trim();
    orders.save(current);
  }

  void setNote(String? note) {
    current.note = (note == null || note.trim().isEmpty) ? null : note.trim();
    orders.save(current);
  }

  void setDeliveryCost(double cost) {
    current.deliveryCost = cost < 0 ? 0 : cost;
    orders.save(current);
  }

  void setTip(double tip) {
    current.tip = tip < 0 ? 0 : tip;
    orders.save(current);
  }

  /// Delivery customer details captured on the till (a walk-in partner has none).
  void setDeliveryCustomer({String? name, String? phone, String? address}) {
    current
      ..customerName = _blankToNull(name)
      ..customerPhone = _blankToNull(phone)
      ..customerAddress = _blankToNull(address);
    orders.save(current);
  }

  /// Attach (or clear, with null) the Odoo customer this sale is for.
  void setCustomer(Customer? c) {
    current.partnerId = c?.id;
    current.customerName = c?.name;
    current.customerPhone = c?.phone;
    orders.save(current);
  }

  // ── hold / recall (open tabs) ────────────────────────────────────

  /// Park the current order on its table/tab and start a fresh one. A no-op if the
  /// current order is empty, so tapping Hold on nothing cannot orphan a blank order.
  void hold({String? table}) {
    final order = current;
    if (order.lines.isEmpty) return;
    if (table != null) order.tableLabel = table.trim();
    order.state = OrderState.held;
    orders.save(order);
    audit.record(cashierId, 'order.held',
        detail: '${order.uuid}|${order.tableLabel ?? ''}');
    _current = Order(deviceId: deviceId, cashierId: cashierId);
  }

  /// Bring a parked order back to the counter to edit or pay. The order currently
  /// on screen is parked first if it has lines, so switching tables never loses it.
  void recall(String uuid) {
    final target = orders.byUuid(uuid);
    if (target == null) return;
    final active = current;
    if (active.uuid != uuid && active.lines.isNotEmpty) {
      active.state = OrderState.held;
      orders.save(active);
    }
    target.state = OrderState.draft;
    orders.save(target);
    _current = target;
  }

  /// Start a brand-new order, parking the current one if it has lines.
  void newOrder() {
    final active = current;
    if (active.lines.isNotEmpty) {
      active.state = OrderState.held;
      orders.save(active);
    }
    _current = Order(deviceId: deviceId, cashierId: cashierId);
  }

  /// Take payment. Writes locally, queues for the server, and starts a fresh order.
  /// Returns the completed order so the caller can print it.
  Order pay({List<OrderPayment> payments = const []}) {
    final order = current;
    order.state = OrderState.paid;
    order.payments = List.of(payments);
    orders.save(order);
    outbox.enqueue('order.push', order.uuid, order.toServerPayload());
    audit.record(cashierId, 'order.paid', detail: order.uuid);
    _current = Order(deviceId: deviceId, cashierId: cashierId);
    return order;
  }

  static String? _blankToNull(String? v) =>
      (v == null || v.trim().isEmpty) ? null : v.trim();
}

/// A modifier the cashier picked, with how many.
class ChosenModifier {
  const ChosenModifier(this.modifier, [this.quantity = 1]);
  final Modifier modifier;
  final int quantity;
}
