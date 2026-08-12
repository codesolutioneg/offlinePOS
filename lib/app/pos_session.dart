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
      taxRate: product.taxRate,
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
    // Consolidate: tapping the same product again bumps the existing line's
    // quantity instead of stacking a duplicate row, the way a till is expected to
    // behave. Only an identical line that has not been fired to the kitchen yet
    // merges: a line already sent, discounted, noted or seat-tagged stays its own
    // row so the kitchen delta and the split maths stay correct.
    final match = _mergeableLineFor(line);
    if (match != null) {
      match.quantity += qty;
    } else {
      current.lines.add(line);
    }
    orders.save(current);
  }

  /// An existing line the freshly built [line] can fold into, or null. Identical
  /// means same product and modifiers, no note/line-discount/seat, and not yet
  /// printed to the kitchen.
  OrderLine? _mergeableLineFor(OrderLine line) {
    for (final l in current.lines) {
      // Every captured field must match, not just the id: a catalogue refresh can
      // change a product's tax, category or name while its price holds, and merging
      // across that would book the new units under the old line's stale metadata.
      if (l.printedToKitchen ||
          l.firedStations.isNotEmpty ||
          l.fireAt != null ||
          l.productId != line.productId ||
          l.unitPrice != line.unitPrice ||
          l.taxRate != line.taxRate ||
          l.categoryId != line.categoryId ||
          l.name != line.name ||
          l.note != null ||
          l.discountPercent != 0 ||
          l.seat != null) {
        continue;
      }
      if (_sameModifiers(l.modifiers, line.modifiers)) return l;
    }
    return null;
  }

  static bool _sameModifiers(List<OrderModifier> a, List<OrderModifier> b) {
    if (a.length != b.length) return false;
    // Include every field that reaches the server payload, so a refreshed modifier
    // with a new backing product or name is not folded under the old one.
    String key(OrderModifier m) =>
        '${m.modifierId}:${m.productId}:${m.name}:${m.quantity}:${m.unitPrice}';
    final ak = a.map(key).toList()..sort();
    final bk = b.map(key).toList()..sort();
    for (var i = 0; i < ak.length; i++) {
      if (ak[i] != bk[i]) return false;
    }
    return true;
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
      // Dine-in and takeaway carry no customer, so switching away from delivery
      // clears the whole customer, not just the address, or a stale partner would
      // ride along on a sale whose UI no longer shows (or lets you clear) it.
      current.deliveryCost = 0;
      current.customerAddress = null;
      current.partnerId = null;
      current.customerName = null;
      current.customerPhone = null;
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
  Order pay({List<OrderPayment> payments = const [], double? cashReceived}) {
    final order = current;
    order.state = OrderState.paid;
    order.payments = List.of(payments);
    order.cashReceived = cashReceived;
    orders.save(order);
    outbox.enqueue('order.push', order.uuid, order.toServerPayload());
    audit.record(cashierId, 'order.paid', detail: order.uuid);
    _current = Order(deviceId: deviceId, cashierId: cashierId);
    return order;
  }

  // ── dine-in: seats, split, move, merge ──────────────────────────

  /// Schedule one line to fire to the kitchen [afterMinutes] from now (0 clears
  /// the timer). Course firing: "send the mains 15 minutes after the starters".
  void setLineFireDelay(String lineUuid, int afterMinutes) {
    final line = current.lines.firstWhere((l) => l.uuid == lineUuid);
    line.fireAt = afterMinutes > 0
        ? DateTime.now().toUtc().add(Duration(minutes: afterMinutes))
        : null;
    orders.save(current);
  }

  /// Schedule the whole order to fire [afterMinutes] from now (0 clears it), so a
  /// cashier can hold a whole ticket back a set time before it hits the kitchen.
  void setOrderFireDelay(int afterMinutes) {
    final at = afterMinutes > 0
        ? DateTime.now().toUtc().add(Duration(minutes: afterMinutes))
        : null;
    for (final l in current.lines) {
      if (!l.printedToKitchen) l.fireAt = at;
    }
    orders.save(current);
  }

  /// Tag a line with the guest/seat it belongs to (null clears it). Drives
  /// split-by-guest and the per-seat kitchen ticket.
  ///
  /// If the line holds more than one unit, one unit is peeled onto the guest and
  /// the rest stay on the original line: repeat taps consolidate into a 2× line,
  /// but that line can still be split a cover at a time.
  void setLineSeat(String lineUuid, int? seat) {
    final line = current.lines.firstWhere((l) => l.uuid == lineUuid);
    final s = (seat != null && seat > 0) ? seat : null;
    if (s != null && line.quantity > 1) {
      line.quantity -= 1;
      current.lines.add(OrderLine(
        productId: line.productId,
        name: line.name,
        quantity: 1,
        unitPrice: line.unitPrice,
        categoryId: line.categoryId,
        taxRate: line.taxRate,
        note: line.note,
        discountPercent: line.discountPercent,
        printedToKitchen: line.printedToKitchen,
        firedStations: List.of(line.firedStations),
        fireAt: line.fireAt,
        seat: s,
        modifiers: [
          for (final m in line.modifiers)
            OrderModifier(
                modifierId: m.modifierId,
                productId: m.productId,
                name: m.name,
                quantity: m.quantity,
                unitPrice: m.unitPrice),
        ],
      ));
    } else {
      line.seat = s;
    }
    orders.save(current);
  }

  /// Explode a consolidated multi-unit line into that many single-unit lines, so a
  /// cashier can note, discount, seat, move or pay one unit on its own after repeat
  /// taps merged them. A no-op on a single-unit or fractional line.
  void splitLineToUnits(String lineUuid) {
    final idx = current.lines.indexWhere((l) => l.uuid == lineUuid);
    if (idx < 0) return;
    final line = current.lines[idx];
    if (line.quantity <= 1 || line.quantity != line.quantity.roundToDouble()) return;
    final n = line.quantity.toInt();
    line.quantity = 1;
    for (var i = 1; i < n; i++) {
      current.lines.insert(
        idx + i,
        OrderLine(
          productId: line.productId,
          name: line.name,
          quantity: 1,
          unitPrice: line.unitPrice,
          categoryId: line.categoryId,
          taxRate: line.taxRate,
          note: line.note,
          discountPercent: line.discountPercent,
          printedToKitchen: line.printedToKitchen,
          firedStations: List.of(line.firedStations),
          fireAt: line.fireAt,
          seat: line.seat,
          modifiers: [
            for (final m in line.modifiers)
              OrderModifier(
                  modifierId: m.modifierId,
                  productId: m.productId,
                  name: m.name,
                  quantity: m.quantity,
                  unitPrice: m.unitPrice),
          ],
        ),
      );
    }
    orders.save(current);
  }

  /// Carve a subset of the current order's lines into their own paid check and
  /// take payment for it, leaving the rest of the table open. This is how a split
  /// bill is settled: each guest/selection becomes its own paid order that syncs on
  /// its own, so the server needs no concept of a split. Returns the paid check for
  /// printing. The order-level discount rides along (it is a percentage, so each
  /// check discounts only its own lines); tip is whatever was tendered on the check.
  Order payCheck(
    List<String> lineUuids, {
    List<OrderPayment> payments = const [],
    double? cashReceived,
    double tip = 0,
  }) {
    final order = current;
    final ids = lineUuids.toSet();
    final taken = order.lines.where((l) => ids.contains(l.uuid)).toList();
    final check = Order(
      deviceId: deviceId,
      cashierId: cashierId,
      type: order.type,
      tableLabel: order.tableLabel,
      guestCount: order.guestCount,
      partnerId: order.partnerId,
      customerName: order.customerName,
      customerPhone: order.customerPhone,
      discountPercent: order.discountPercent,
      discountReason: order.discountReason,
      tip: tip,
      lines: taken,
    )
      ..state = OrderState.paid
      ..payments = List.of(payments)
      ..cashReceived = cashReceived;
    orders.save(check);
    outbox.enqueue('order.push', check.uuid, check.toServerPayload());
    audit.record(cashierId, 'order.paid', detail: '${check.uuid}|split check');
    order.lines.removeWhere((l) => ids.contains(l.uuid));
    if (order.lines.isEmpty) {
      // Whole table settled: discard the now-empty running order and start fresh.
      orders.delete(order.uuid);
      _current = Order(deviceId: deviceId, cashierId: cashierId);
    } else {
      orders.save(order);
    }
    return check;
  }

  /// Bake an order-level discount into the given lines' own discount, so lines that
  /// leave the order (moved or merged) keep the price they had rather than picking
  /// up the destination order's discount instead. A no-op when there is no
  /// whole-order discount to carry.
  static void _carryOrderDiscount(double orderDiscountPercent, List<OrderLine> lines) {
    if (orderDiscountPercent <= 0) return;
    final f = 1 - orderDiscountPercent.clamp(0, 100) / 100;
    for (final l in lines) {
      final combined = l.lineDiscountFactor * f;
      l.discountPercent = (1 - combined) * 100;
    }
  }

  /// Push an order's whole-order discount down onto its own lines and clear it, so
  /// the order carries no order-level discount. Used before foreign lines join a
  /// table: with every discount now line-level, a moved-in line (already priced)
  /// cannot be discounted a second time by the destination's order discount.
  static void _flattenOrderDiscount(Order o) {
    if (o.discountPercent <= 0) return;
    _carryOrderDiscount(o.discountPercent, o.lines);
    o.discountPercent = 0;
    o.discountReason = null;
  }

  /// Move a subset of the current order's lines onto another table's open tab
  /// (creating one if the table has none), then leave the rest here. Returns the
  /// target order. Used for "move items to another table". A whole-order discount on
  /// the source is folded into the moved lines so their price does not change.
  Order moveLinesToTable(Set<String> lineUuids, String targetTableLabel) {
    final order = current;
    // Moving onto the table the order is already on would fork a duplicate tab for
    // the same table, so it is a no-op.
    if (targetTableLabel == order.tableLabel) return order;
    final taken = order.lines.where((l) => lineUuids.contains(l.uuid)).toList();
    if (taken.isEmpty) return order;
    _carryOrderDiscount(order.discountPercent, taken);
    final target = orders.held().firstWhere(
          (o) => o.tableLabel == targetTableLabel && o.uuid != order.uuid,
          orElse: () => Order(
            deviceId: deviceId,
            cashierId: cashierId,
            type: OrderType.dineIn,
            tableLabel: targetTableLabel,
          )..state = OrderState.held,
        );
    // Flatten the target's own discount to line level first, so the moved lines
    // (already priced) are not discounted a second time by it.
    _flattenOrderDiscount(target);
    target.lines.addAll(taken);
    orders.save(target);
    order.lines.removeWhere((l) => lineUuids.contains(l.uuid));
    audit.record(cashierId, 'order.moved',
        detail: '${order.uuid}->${target.uuid}|${taken.length} line(s)');
    if (order.lines.isEmpty) {
      orders.delete(order.uuid);
      _current = Order(deviceId: deviceId, cashierId: cashierId);
    } else {
      orders.save(order);
    }
    return target;
  }

  /// Fold another table's open order into the current one, then discard the source.
  /// Used for "merge tables". A no-op if the source is missing or is this order.
  void mergeOrderInto(String sourceUuid) {
    final source = orders.byUuid(sourceUuid);
    if (source == null || source.uuid == current.uuid) return;
    // Keep both tables' discounts with their own items: fold the source discount
    // into the incoming lines and flatten this table's discount onto its existing
    // lines, so neither set is discounted twice once they share one order.
    _carryOrderDiscount(source.discountPercent, source.lines);
    _flattenOrderDiscount(current);
    current.lines.addAll(source.lines);
    orders.save(current);
    orders.delete(source.uuid);
    audit.record(cashierId, 'order.merged',
        detail: '${source.uuid}->${current.uuid}|${source.lines.length} line(s)');
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
