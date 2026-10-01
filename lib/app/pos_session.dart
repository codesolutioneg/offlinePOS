import 'dart:async';

import '../core/audit/audit_log.dart';
import '../core/db/catalogue_store.dart';
import '../core/db/order_store.dart';
import '../core/db/settings_store.dart';
import '../core/sync/dishflow_mirror.dart';
import '../core/sync/ecommerce_orders_client.dart';
import '../core/sync/outbox.dart';
import '../domain/catalogue.dart';
import '../domain/delivery.dart';
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
    this.settings,
    this.taxRateFor,
    this.serviceChargeFor,
    this.nextOrderNo,
    this.onRinging,
    this.shiftOpenedAt,
    this.clock,
    this.tagOrder,
  });

  /// Stamps every order this session creates (a new bill, a split check, the tab a
  /// move opens) before it is first saved. The Stress Lab marks its own this way,
  /// so a check carved off a lab table is a lab order too and cannot leave the till.
  final void Function(Order order)? tagOrder;

  Order _tagged(Order o) {
    tagOrder?.call(o);
    return o;
  }

  /// When the open shift started, or null with none open. A sale is never stamped
  /// before it: a device clock set back mid-shift would otherwise put the sale
  /// outside the shift's window, where neither the Z nor the Odoo close finds it.
  final DateTime? Function()? shiftOpenedAt;

  /// The till's clock. Injected by tests; the device clock otherwise.
  final DateTime Function()? clock;

  final CatalogueStore catalogue;
  final OrderStore orders;
  final Outbox outbox;
  final AuditLog audit;
  final String deviceId;
  final String cashierId;

  /// When set, paid sales are also queued for the Dishflow owner mirror.
  final SettingsStore? settings;

  /// Resolves the tax rate for a line's category in the current order type, or null
  /// to keep the product's own rate. Lets a shop set tax per category per order type
  /// (e.g. 0% takeaway). Null for the whole session means "use product rates".
  final double? Function(int? categoryId, OrderType type)? taxRateFor;

  /// Resolves the service percentage a new bill of this order type carries (0 for
  /// none), so the shop's setting is stamped onto the order once instead of being read
  /// every time a total is asked for. Null for the whole session means no service
  /// charge anywhere.
  final double Function(OrderType type)? serviceChargeFor;

  /// Hands out the next human order number for this till. Null means orders carry
  /// no number and everything falls back to the uuid tail, which is what the till
  /// showed before there was a counter.
  final String Function()? nextOrderNo;

  /// Told when a line goes onto an order that has no number yet, so a number that
  /// has to come over the network can be on its way before [nextOrderNo] is asked.
  final void Function()? onRinging;

  /// Give [o] its number the first time it leaves the cashier's hands (parked,
  /// paid, or sent to kitchen). Never re-numbered: a table that is recalled,
  /// split or corrected keeps the number the guests and the kitchen already have.
  void _stampOrderNo(Order o) {
    if (o.orderNo != null) return;
    o.orderNo = nextOrderNo?.call();
  }

  /// Stamp the moment [o] is paid as the moment of the sale; see [shiftOpenedAt].
  void _stampSaleTime(Order o) {
    final now = (clock?.call() ?? DateTime.now()).toUtc();
    final opened = shiftOpenedAt?.call()?.toUtc();
    o.createdAt = opened != null && now.isBefore(opened) ? opened : now;
  }

  /// Public stamp so the kitchen fire path can number the bill before paper goes
  /// out — the KOT and the sale receipt must quote the same searchable sequence.
  void ensureOrderNo(Order o) => _stampOrderNo(o);

  /// Apply the configured category/order-type tax rate to a line, if one is set.
  /// A line whose category is not in the matrix keeps the rate it already has.
  void _applyTax(OrderLine line) {
    // The matrix rate for this category/order type, or the product's base rate when
    // the type has no override, so switching away from a configured type restores
    // the original rate rather than leaving the last override stuck on the line.
    line.taxRate = taxRateFor?.call(line.categoryId, current.type) ?? line.baseTaxRate;
  }

  /// Stamp the shop's current service percentage for [o]'s order type onto the bill.
  /// Called when a bill is opened and when its type changes, never when a total is
  /// read: what the guests are shown is what they pay, whatever happens to the setting
  /// while they eat.
  void _stampServiceCharge(Order o) {
    o.serviceChargePercent = serviceChargeFor?.call(o.type) ?? 0;
  }

  /// A fresh empty bill for this till, with the service charge for its type on it.
  Order _blankOrder() {
    final o = _tagged(Order(deviceId: deviceId, cashierId: cashierId));
    _stampServiceCharge(o);
    return o;
  }

  Order? _current;

  /// The order being built. Restored from disk if one was left unfinished, which is
  /// what gives a cashier their work back after a crash or a closed window. A restored
  /// draft keeps the service percentage it was opened with.
  ///
  /// Only this cashier's own draft comes back. A cart another cashier left behind
  /// is parked as a tab under their name instead: taking the money on it here would
  /// file the sale under whoever rang it and step around table security. Any
  /// further draft of this cashier's with lines is parked too: only one can be on
  /// the counter, and a draft that is not on it is on no screen at all.
  Order get current {
    return _current ??= _restoreDraft() ?? _blankOrder();
  }

  Order? _restoreDraft() {
    Order? mine;
    for (final d in orders.drafts()) {
      if (d.cashierId == cashierId && mine == null) {
        mine = d;
      } else if (d.lines.isNotEmpty) {
        _park(d);
      }
    }
    return mine;
  }

  void _park(Order order) {
    order.state = OrderState.held;
    _stampOrderNo(order);
    orders.save(order);
    audit.record(cashierId, 'order.parked',
        detail: '${order.uuid}|left by ${order.cashierId}');
  }

  bool get hasLines => current.lines.isNotEmpty;
  double get total => current.total;

  /// How many orders are parked on tables/tabs right now.
  int get heldCount => orders.held().length;

  /// Add a product, applying chosen modifiers. Persisted immediately.
  void addProduct(Product product,
      {List<ChosenModifier> chosen = const [], double qty = 1}) {
    if (current.orderNo == null) onRinging?.call();
    final line = OrderLine(
      productId: product.id,
      // Captured now, like the price: what this line books against in Odoo must not
      // change because somebody relinked the product afterwards.
      odooProductId: product.odooId,
      name: product.displayName,
      quantity: qty,
      unitPrice: product.price,
      categoryId: product.categoryId,
      // Start from the product's rate, then let the category/order-type matrix
      // override it below.
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
    // Let the category/order-type tax matrix override the product rate for this line.
    _applyTax(line);
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
  /// printed to the kitchen. [exceptUuid] skips one row, so a line already in the
  /// cart being re-tested after an edit cannot match itself.
  OrderLine? _mergeableLineFor(OrderLine line, {String? exceptUuid}) {
    for (final l in current.lines) {
      if (l.uuid == exceptUuid) continue;
      // Every captured field must match, not just the id: a catalogue refresh can
      // change a product's tax, category or name while its price holds, and merging
      // across that would book the new units under the old line's stale metadata.
      if (l.printedToKitchen ||
          l.firedStations.isNotEmpty ||
          l.fireAt != null ||
          l.productId != line.productId ||
          l.unitPrice != line.unitPrice ||
          l.taxRate != line.taxRate ||
          // Also the base rate: under an override two lines can share a visible rate
          // (e.g. both 0% takeaway) while their product rates differ, and merging
          // would lose the newer unit's fallback when the override later lifts.
          l.baseTaxRate != line.baseTaxRate ||
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
  OrderLine? voidLine(String lineUuid, String reason, {String? approvedBy}) {
    final idx = current.lines.indexWhere((l) => l.uuid == lineUuid);
    if (idx < 0) return null;
    final line = current.lines.removeAt(idx);
    orders.save(current);
    final by = (approvedBy != null && approvedBy.isNotEmpty)
        ? '|by:$approvedBy'
        : '';
    audit.record(cashierId, 'line.voided',
        detail: '${current.uuid}|${line.name} x${line.quantity}|$reason$by');
    return line;
  }

  /// Void [qty] units of a multi-unit line. When [qty] covers the whole line this
  /// is [voidLine]; otherwise the line stays with the remainder and a detached
  /// snapshot (quantity = [qty]) is returned for the kitchen cancel / deletion
  /// slips so the pass only bins what was voided — e.g. void 1 of 8.
  ///
  /// Partial voids only apply to whole-number lines; a weighed/fractional line
  /// can only be taken off in full.
  OrderLine? voidQuantity(String lineUuid, double qty, String reason,
      {String? approvedBy}) {
    final idx = current.lines.indexWhere((l) => l.uuid == lineUuid);
    if (idx < 0) return null;
    final line = current.lines[idx];
    if (qty <= 0) return null;
    if (qty >= line.quantity ||
        line.quantity != line.quantity.roundToDouble() ||
        qty != qty.roundToDouble()) {
      return voidLine(lineUuid, reason, approvedBy: approvedBy);
    }
    line.quantity -= qty;
    orders.save(current);
    final voided = OrderLine(
      productId: line.productId,
      odooProductId: line.odooProductId,
      name: line.name,
      quantity: qty,
      unitPrice: line.unitPrice,
      categoryId: line.categoryId,
      taxRate: line.taxRate,
      baseTaxRate: line.baseTaxRate,
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
    );
    final by = (approvedBy != null && approvedBy.isNotEmpty)
        ? '|by:$approvedBy'
        : '';
    audit.record(cashierId, 'line.voided',
        detail: '${current.uuid}|${line.name} x$qty|$reason$by');
    return voided;
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

  /// Sell one line at a price the catalogue does not carry (damaged goods, a
  /// promise made at the door, a manager's call). Gated at the call site and
  /// recorded here with what it was and what it became: a price nobody can trace
  /// back is how a till leaks money.
  ///
  /// Modifiers keep the price they were captured at, because the override is a
  /// decision about the item, not about what was added to it. A negative price is
  /// refused: money is given back through a refund, which is reversible and books.
  void setLinePrice(String lineUuid, double price) {
    if (price < 0) return;
    final line = current.lines.firstWhere((l) => l.uuid == lineUuid);
    final was = line.unitPrice;
    if (was == price) return;
    line.unitPrice = price;
    orders.save(current);
    audit.record(cashierId, 'line.price_override',
        detail: '${current.uuid}|${line.name}|$was|$price');
  }

  /// Replace what a line in the cart was ordered with, repriced from the new
  /// selection. [chosen] is the whole answer, so an empty list clears the line's
  /// modifiers. This is the correction path for "wrong size, no cheese": without it
  /// the only remedy is to void the line and ring it again.
  ///
  /// Refused once the kitchen holds the line. Food on the pass is being cooked to the
  /// ticket that was sent, so changing what it says here would leave the till and the
  /// kitchen describing two different dishes with nothing printed to reconcile them.
  /// That is the same restriction the inline quantity edit and the trash already
  /// carry, and taking the item off still goes through Void, which gates, prints a
  /// cancel slip and audits. The sell screen says so rather than greying the entry
  /// out, because a cashier who is told to void and re-ring can act on that.
  ///
  /// A percentage option is priced against this line's own unit price: that is the
  /// parent it is being attached to now. A price override on the line therefore
  /// reaches a choice made after it, while the choices already on the line keep what
  /// they were captured at, exactly as [setLinePrice] promises.
  ///
  /// The merge rule is the one a freshly rung line gets, through the same
  /// [_mergeableLineFor] test: if the edit has made this line identical to another
  /// plain line, it folds into it the way a repeat tap would, because the cart has no
  /// way left to tell the two rows apart and showing both is how a cashier ends up
  /// double-checking a bill. A line the cashier has marked out (a note, a line
  /// discount, a seat, a fire timer) or that the kitchen already holds folds neither
  /// way, so anything deliberately kept separate stays separate.
  void setLineModifiers(String lineUuid, List<ChosenModifier> chosen) {
    final idx = current.lines.indexWhere((l) => l.uuid == lineUuid);
    if (idx < 0) return;
    final line = current.lines[idx];
    if (line.printedToKitchen || line.firedStations.isNotEmpty) return;
    // What each option was already charged at. An option that is still selected
    // keeps that figure rather than being priced again, because the price it was
    // captured at is the one the customer was quoted. Repricing here would move a
    // percentage or a size option every time somebody opened the sheet and pressed
    // save on a line whose own price had since been overridden, so confirming a
    // choice nobody changed would change the bill.
    final captured = {
      for (final m in line.modifiers) (m.modifierId, m.quantity): m.unitPrice,
    };
    final next = [
      for (final c in chosen)
        OrderModifier(
          modifierId: c.modifier.id,
          productId: c.modifier.productId,
          name: c.modifier.name,
          quantity: c.quantity.toDouble(),
          // Only a choice that was not already on the line at this quantity is
          // priced from where the line stands now.
          unitPrice: captured[(c.modifier.id, c.quantity.toDouble())] ??
              c.modifier.priceFor(line.unitPrice),
        ),
    ];
    if (_sameModifiers(line.modifiers, next)) return;
    final was = _modifierSummary(line.modifiers);
    line.modifiers
      ..clear()
      ..addAll(next);
    final now = _modifierSummary(line.modifiers);
    if (line.note == null &&
        line.discountPercent == 0 &&
        line.seat == null &&
        line.fireAt == null) {
      final match = _mergeableLineFor(line, exceptUuid: line.uuid);
      if (match != null) {
        match.quantity += line.quantity;
        current.lines.removeAt(idx);
      }
    }
    orders.save(current);
    // A modifier carries money, so the change is traced like a line discount or a
    // price override is: what it was and what it became.
    audit.record(cashierId, 'line.modifiers_changed',
        detail: '${current.uuid}|${line.name}|$was|$now');
  }

  /// A line's modifiers as one readable string for the audit trail.
  static String _modifierSummary(List<OrderModifier> mods) => mods.isEmpty
      ? 'none'
      : mods
          .map((m) =>
              m.quantity > 1 ? '${m.name} x${m.quantity.toStringAsFixed(0)}' : m.name)
          .join(', ');

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
    order.deliveryChannel = null;
    order.companyOrderNo = null;
    order.driverId = null;
    order.driverName = null;
    order.driverPhone = null;
    order.deliveryStatus = DeliveryStatus.received;
    order.shippingZoneId = null;
    order.shippingZoneName = null;
    order.serviceFee = 0;
    order.ecommerceOrderId = null;
    order.tip = 0;
    // An emptied order is a fresh bill on the same row, so it takes the service charge
    // the shop is on now rather than keeping a stamp from the sale that was cleared.
    _stampServiceCharge(order);
    orders.save(order);
  }

  /// Apply a whole-order discount (0-100%) with an optional reason.
  void setDiscount(double percent, {String? reason}) {
    current.discountPercent = percent.clamp(0, 100).toDouble();
    current.discountReason = reason;
    orders.save(current);
  }

  /// Set the order type. Clears delivery details when leaving delivery, and
  /// clears subtype-only fields when moving between Dishflow delivery kinds.
  void setOrderType(OrderType type) {
    final prev = current.type;
    current.type = type;
    // Service follows the type: what is table service dine-in is not table service in a
    // takeaway bag. Re-stamped here, on the bill, so the total still never depends on
    // reading a setting late.
    _stampServiceCharge(current);
    // Tax can differ by order type (e.g. 0% takeaway), so re-resolve every line's
    // rate for the new type. Lines whose category is not in the matrix are untouched.
    for (final line in current.lines) {
      _applyTax(line);
    }
    // Covers belong to a bill eaten at the table.
    if (type != OrderType.dineIn) current.guestCount = null;
    if (!type.isDelivery) {
      // The customer survives the switch: every order type can name one, and the
      // till shows and clears it on all of them. Only what is delivery's alone goes,
      // because an address and a delivery charge mean nothing on a counter sale.
      current.deliveryCost = 0;
      current.customerAddress = null;
      // The same reasoning covers the delivery-only trio: there is no channel, no
      // aggregator reference and nobody driving a sale handed over the counter.
      current.deliveryChannel = null;
      current.companyOrderNo = null;
      current.driverId = null;
      current.driverName = null;
      current.driverPhone = null;
      current.deliveryStatus = DeliveryStatus.received;
      current.shippingZoneId = null;
      current.shippingZoneName = null;
      current.serviceFee = 0;
    } else if (prev != type) {
      // Company # / channel only belong on aggregator delivery.
      if (!type.needsCompanyOrderNo) {
        current.companyOrderNo = null;
        current.deliveryChannel = null;
      }
      // Zone fees and rider are store-delivery concerns; car is a plain till sale.
      if (!type.usesDeliveryZones) {
        current.deliveryCost = 0;
        current.shippingZoneId = null;
        current.shippingZoneName = null;
      }
      if (!type.needsDeliveryCustomer) {
        current.customerAddress = null;
        current.driverId = null;
        current.driverName = null;
        current.driverPhone = null;
        current.serviceFee = 0;
      }
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

  /// Park this bill on [label] even when it has no lines yet, so the floor on
  /// every till colours the table busy the moment it is tapped. Hold refuses an
  /// empty cart because that would orphan a blank tab; seating is the one empty
  /// write that is a fact about the room rather than about the food.
  void claimSeat(String label) {
    final trimmed = label.trim();
    if (trimmed.isEmpty) return;
    current.tableLabel = trimmed;
    current.state = OrderState.held;
    orders.save(current);
    audit.record(cashierId, 'table.claimed',
        detail: '${current.uuid}|$trimmed');
  }

  /// Stamp that the check went to the printer, so the floor can colour the table
  /// as billed while it is still open.
  void markBillPrinted([Order? order]) {
    final o = (order == null || order.uuid == current.uuid)
        ? current
        : (orders.byUuid(order.uuid) ?? order);
    o.billPrintedAt = DateTime.now().toUtc();
    orders.save(o);
  }

  /// Every open check on the current order's table, the current one first: the
  /// checks a split made, plus any other bill parked there on this till.
  List<Order> tableChecks() {
    final label = current.tableLabel;
    if (label == null) return [current];
    return [
      current,
      for (final o in orders.held())
        if (o.tableLabel == label && o.uuid != current.uuid) o,
    ];
  }

  /// Open another check on a table that already has one, without folding the
  /// lines together. The bills stay linked so the floor shows one occupied tile
  /// with several tabs.
  void openLinkedTab(String tableLabel) {
    final label = tableLabel.trim();
    if (label.isEmpty) return;
    final type =
        current.type.seatsAtTable ? current.type : OrderType.dineIn;
    startFresh(type);
    claimSeat(label);
    _linkCurrentToTable(label);
  }

  /// Keep [sourceUuid] as its own cart on this table rather than folding its
  /// lines in. The source table is left empty.
  void mergeAsSeparateCarts(String sourceUuid) {
    final source = orders.byUuid(sourceUuid);
    final destLabel = current.tableLabel;
    if (source == null || source.uuid == current.uuid || destLabel == null) {
      return;
    }
    source.tableLabel = destLabel;
    orders.save(source);
    _linkPair(current, source);
    _linkCurrentToTable(destLabel);
    audit.record(cashierId, 'order.linked',
        detail: '${source.uuid}->${current.uuid}|$destLabel');
  }

  /// Move the current tab onto an empty [targetLabel] and drop the sibling
  /// links, which is how a waiter undoes a separate-carts merge.
  void splitTabToTable(String targetLabel) {
    final trimmed = targetLabel.trim();
    if (trimmed.isEmpty || trimmed == current.tableLabel) return;
    if (tableBusyElsewhere(trimmed)) return;
    _detachFromSiblings(current);
    current.tableLabel = trimmed;
    orders.save(current);
    audit.record(cashierId, 'order.split_table',
        detail: '${current.uuid}|$trimmed');
  }

  /// Leave the floor: drop the table label and, on a dine-in, become a takeaway
  /// so the kitchen ticket no longer names a seat.
  void clearTableToTakeaway() {
    _detachFromSiblings(current);
    current.tableLabel = null;
    if (current.type == OrderType.dineIn) {
      setOrderType(OrderType.takeaway);
      return;
    }
    orders.save(current);
  }

  void _linkCurrentToTable(String label) {
    for (final s in orders.occupyingAnywhere()) {
      if (s.tableLabel != label || s.uuid == current.uuid) continue;
      _linkPair(current, s);
    }
    orders.save(current);
  }

  void _linkPair(Order a, Order b) {
    if (a.uuid == b.uuid) return;
    if (!a.linkedOrderUuids.contains(b.uuid)) a.linkedOrderUuids.add(b.uuid);
    if (!b.linkedOrderUuids.contains(a.uuid)) b.linkedOrderUuids.add(a.uuid);
    orders.save(a);
    orders.save(b);
  }

  void _detachFromSiblings(Order order) {
    final ids = List<String>.of(order.linkedOrderUuids);
    if (ids.isEmpty) return;
    order.linkedOrderUuids.clear();
    for (final id in ids) {
      final other = orders.byUuid(id);
      if (other == null) continue;
      other.linkedOrderUuids.remove(order.uuid);
      orders.save(other);
    }
  }

  void setNote(String? note) {
    current.note = (note == null || note.trim().isEmpty) ? null : note.trim();
    orders.save(current);
  }

  void setDeliveryCost(double cost) {
    current.deliveryCost = cost < 0 ? 0 : cost;
    orders.save(current);
  }

  /// Flat service fee (Dishflow manual), separate from the %-based service charge.
  void setServiceFee(double fee) {
    current.serviceFee = fee < 0 ? 0 : fee;
    orders.save(current);
  }

  void setShippingZone(DeliveryZone? zone) {
    current.shippingZoneId = zone?.id;
    current.shippingZoneName = zone?.name;
    if (zone != null) current.deliveryCost = zone.fee < 0 ? 0 : zone.fee;
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

  /// Where this delivery came from and the number that channel calls it, both local
  /// to the till. A channel that is invoiced as a company also carries its partner,
  /// so the sale books against the aggregator rather than against the guest.
  ///
  /// [previous] is the channel the order was already on, so moving off a company
  /// channel takes its partner with it. Without that, a sale switched from an
  /// aggregator to the shop's own phone would still be booked against the
  /// aggregator, and the money would land on the wrong account.
  void setDeliveryChannel(DeliveryChannel? channel,
      {String? companyOrderNo, DeliveryChannel? previous}) {
    if (previous?.partnerId != null && current.partnerId == previous!.partnerId) {
      current.partnerId = null;
    }
    current
      ..deliveryChannel = channel?.name
      ..companyOrderNo = _blankToNull(companyOrderNo);
    if (channel?.partnerId != null) current.partnerId = channel!.partnerId;
    orders.save(current);
  }

  /// Who is carrying this delivery. Stamps id + name + phone (Dishflow assign).
  /// Advancing from `received` → `sent` when a driver is first assigned.
  void setDriver(Driver? driver) {
    current.driverId = driver?.id;
    current.driverName = driver == null ? null : _blankToNull(driver.name);
    current.driverPhone = driver?.phone;
    if (driver != null &&
        current.type.isDelivery &&
        current.deliveryStatus == DeliveryStatus.received) {
      current.deliveryStatus = DeliveryStatus.sent;
    }
    orders.save(current);
  }

  /// Assign / reassign a driver on any delivery bag (held or paid), for the board.
  void assignDriverTo(Order order, Driver? driver) {
    order.driverId = driver?.id;
    order.driverName = driver == null ? null : _blankToNull(driver.name);
    order.driverPhone = driver?.phone;
    if (driver != null && order.deliveryStatus == DeliveryStatus.received) {
      order.deliveryStatus = DeliveryStatus.sent;
    }
    orders.save(order);
    if (order.state == OrderState.paid || order.state == OrderState.synced) {
      _mirrorPaid(order);
    }
  }

  void setDeliveryStatus(Order order, DeliveryStatus status) {
    order.deliveryStatus = status;
    orders.save(order);
    if (order.state == OrderState.paid || order.state == OrderState.synced) {
      _mirrorPaid(order);
    }
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
    _stampOrderNo(order);
    orders.save(order);
    audit.record(cashierId, 'order.held',
        detail: '${order.uuid}|${order.tableLabel ?? ''}');
    _current = _blankOrder();
  }

  /// Bring a parked order back to the counter to edit or pay. The order currently
  /// on screen is parked first if it has lines, so switching tables never loses it.
  ///
  /// Refuses (false) a sale that is already paid or synced: a list read before the
  /// payment and tapped after it would otherwise put the sale back on the counter
  /// to be charged a second time. Correcting a paid sale goes through reopen.
  bool recall(String uuid) {
    final target = orders.byUuid(uuid);
    if (target == null) return false;
    if (target.state == OrderState.paid || target.state == OrderState.synced) {
      return false;
    }
    final active = current;
    if (active.uuid != uuid && active.lines.isNotEmpty) {
      active.state = OrderState.held;
      orders.save(active);
    } else if (active.uuid != uuid) {
      _detachFromSiblings(active);
      orders.delete(active.uuid);
    }
    target.state = OrderState.draft;
    orders.save(target);
    _current = target;
    return true;
  }

  /// Start a brand-new order, parking the current one if it has lines.
  /// An empty seated claim is dropped so backing out of a tap does not leave the
  /// table busy on every till.
  void newOrder() {
    final active = current;
    if (active.lines.isNotEmpty) {
      active.state = OrderState.held;
      orders.save(active);
    } else {
      _detachFromSiblings(active);
      orders.delete(active.uuid);
    }
    _current = _blankOrder();
  }

  /// Stamp a different cashier on the bill being built (who opened the table).
  ///
  /// The till may be signed in as Setup or a manager while a waiter opens the
  /// table under their own PIN: the order's cashier is that waiter so reopen
  /// security and reports match who actually owns the tab.
  void rebindCashier(String newCashierId) {
    if (current.cashierId == newCashierId) return;
    final rebound = Order.fromMap({...current.toMap(), 'cashier_id': newCashierId});
    _current = rebound;
    orders.save(rebound);
  }

  /// Begin a fresh order of [type]. A current order with lines is parked (held); an
  /// empty draft is discarded rather than left behind, so starting from the floor
  /// home never orphans a stale empty draft that could be restored later.
  void startFresh(OrderType type) {
    final active = current;
    if (active.lines.isNotEmpty) {
      active.state = OrderState.held;
      orders.save(active);
    } else {
      _detachFromSiblings(active);
      orders.delete(active.uuid);
    }
    _current = _blankOrder();
    setOrderType(type);
  }

  /// Take payment. Writes locally, queues for the server, and starts a fresh order.
  /// Returns the completed order so the caller can print it, or null when there is
  /// nothing on the counter: a second tap on Charge would otherwise book an empty
  /// sale carrying real money.
  Order? pay({List<OrderPayment> payments = const [], double? cashReceived}) {
    final order = current;
    if (order.lines.isEmpty) return null;
    _detachFromSiblings(order);
    order.state = OrderState.paid;
    _stampSaleTime(order);
    _stampOrderNo(order);
    order.payments = List.of(payments);
    order.cashReceived = cashReceived;
    _bookPaid(order, order.uuid);
    _current = _blankOrder();
    return order;
  }

  /// Take one part payment toward the current order (an even-split share, or any
  /// partial amount), keeping the table open on a running balance until it is
  /// covered. The share's tenders accrue on the order; once they settle the total
  /// the order is finalized like a normal sale and a fresh order starts. Returns the
  /// remaining balance (0 when fully paid). While a balance remains the order is
  /// held, so it survives a restart and shows on the floor/open tabs. Null when
  /// there is nothing on the counter to pay toward.
  double? payShare({List<OrderPayment> payments = const [], double? cashReceived, double tip = 0}) {
    final order = current;
    if (order.lines.isEmpty) return null;
    // A tip on a share raises what is owed too, so the tendered amount (which
    // includes the tip) nets correctly against the balance rather than paying down
    // the food. Additive, since several shares can each carry a tip.
    if (tip > 0) order.tip += tip;
    _stampOrderNo(order);
    order.payments = [...order.payments, ...payments];
    if (cashReceived != null) {
      order.cashReceived = (order.cashReceived ?? 0) + cashReceived;
    }
    if (order.balance <= 0.001) {
      _detachFromSiblings(order);
      order.state = OrderState.paid;
      _stampSaleTime(order);
      _bookPaid(order, '${order.uuid}|even split settled');
      _current = _blankOrder();
      return 0;
    }
    order.state = OrderState.held;
    orders.save(order);
    return order.balance;
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
        odooProductId: line.odooProductId,
        name: line.name,
        quantity: 1,
        unitPrice: line.unitPrice,
        categoryId: line.categoryId,
        taxRate: line.taxRate,
        baseTaxRate: line.baseTaxRate,
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

  /// Put the whole line on guest [seat] (0 or less clears it), every unit with it:
  /// the cart's Seat (+)/(-) steps a line from guest to guest.
  void moveLineToSeat(String lineUuid, int seat) {
    final i = current.lines.indexWhere((l) => l.uuid == lineUuid);
    if (i < 0) return;
    current.lines[i].seat = seat > 0 ? seat : null;
    orders.save(current);
  }

  /// Ring [extra] more of a line the kitchen already has. The sent line keeps what
  /// the kitchen was told; the extra goes on an unsent copy (same item, choices,
  /// price, note, discount, seat) right under it, so the next Send fires only the
  /// difference. A copy already waiting to be sent takes the units instead of a
  /// second row. Returns the uuid of the line that took them, null if none.
  String? addMoreOf(String lineUuid, double extra) {
    if (extra <= 0) return null;
    final idx = current.lines.indexWhere((l) => l.uuid == lineUuid);
    if (idx < 0) return null;
    final src = current.lines[idx];
    for (final l in current.lines) {
      if (l.uuid == src.uuid ||
          l.printedToKitchen ||
          l.firedStations.isNotEmpty ||
          l.fireAt != null ||
          l.productId != src.productId ||
          l.unitPrice != src.unitPrice ||
          l.taxRate != src.taxRate ||
          l.baseTaxRate != src.baseTaxRate ||
          l.categoryId != src.categoryId ||
          l.name != src.name ||
          l.note != src.note ||
          l.discountPercent != src.discountPercent ||
          l.seat != src.seat ||
          !_sameModifiers(l.modifiers, src.modifiers)) {
        continue;
      }
      l.quantity += extra;
      orders.save(current);
      return l.uuid;
    }
    final more = OrderLine(
      productId: src.productId,
      odooProductId: src.odooProductId,
      name: src.name,
      quantity: extra,
      unitPrice: src.unitPrice,
      categoryId: src.categoryId,
      taxRate: src.taxRate,
      baseTaxRate: src.baseTaxRate,
      note: src.note,
      discountPercent: src.discountPercent,
      seat: src.seat,
      modifiers: [
        for (final m in src.modifiers)
          OrderModifier(
              modifierId: m.modifierId,
              productId: m.productId,
              name: m.name,
              quantity: m.quantity,
              unitPrice: m.unitPrice),
      ],
    );
    current.lines.insert(idx + 1, more);
    orders.save(current);
    return more.uuid;
  }

  /// Peel [qty] units off a line into a new line and return its uuid, so a subset
  /// of a multi-unit line can be paid or moved on its own (split by item with a
  /// quantity). Returns the original uuid when [qty] covers the whole line, and
  /// null when the line is gone. Only whole units are peeled; a fractional/weighed
  /// line can only be taken in full.
  String? splitOffQuantity(String lineUuid, double qty) {
    final idx = current.lines.indexWhere((l) => l.uuid == lineUuid);
    if (idx < 0) return null;
    final line = current.lines[idx];
    if (qty >= line.quantity ||
        qty <= 0 ||
        line.quantity != line.quantity.roundToDouble() ||
        qty != qty.roundToDouble()) {
      return lineUuid;
    }
    line.quantity -= qty;
    final peeled = OrderLine(
      productId: line.productId,
      odooProductId: line.odooProductId,
      name: line.name,
      quantity: qty,
      unitPrice: line.unitPrice,
      categoryId: line.categoryId,
      taxRate: line.taxRate,
        baseTaxRate: line.baseTaxRate,
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
    );
    current.lines.insert(idx + 1, peeled);
    orders.save(current);
    return peeled.uuid;
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
          odooProductId: line.odooProductId,
          name: line.name,
          quantity: 1,
          unitPrice: line.unitPrice,
          categoryId: line.categoryId,
          taxRate: line.taxRate,
        baseTaxRate: line.baseTaxRate,
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

  /// Lay the table's bills out as [checks] (each a list of line slices), one check
  /// per non-empty entry. [among] names the checks already open on the table (the
  /// current order is always one of them); they take the entries in order, the
  /// current order first, and each further entry becomes a new held order linked
  /// to the table's tabs, so the floor offers it like any second tab. An existing
  /// check left with nothing is closed. A line cut across checks becomes one line
  /// per slice (a shared item carries a fractional quantity); lines no entry names
  /// stay where they were. Returns the checks in entry order.
  List<Order> splitIntoChecks(
      List<List<({String line, double quantity})>> checks,
      {List<Order> among = const []}) {
    final order = current;
    final existing = [
      order,
      for (final o in among)
        if (o.uuid != order.uuid) orders.byUuid(o.uuid) ?? o,
    ];
    final byUuid = {
      for (final o in existing)
        for (final l in o.lines) l.uuid: l,
    };
    final slices = <String, int>{};
    for (final c in checks) {
      for (final s in c) {
        slices[s.line] = (slices[s.line] ?? 0) + 1;
      }
    }
    final groups = <List<OrderLine>>[];
    for (final c in checks) {
      final g = <OrderLine>[];
      for (final s in c) {
        final src = byUuid[s.line];
        if (src == null || s.quantity <= 0) continue;
        g.add(slices[s.line] == 1 && (s.quantity - src.quantity).abs() < 1e-9
            ? src
            : _copyLine(src, s.quantity));
      }
      if (g.isNotEmpty) groups.add(g);
    }
    if (groups.isEmpty || (existing.length == 1 && groups.length < 2)) {
      return existing;
    }
    // Lines are about to cross between bills, so a whole-order discount that is
    // not the same on every bill moves down onto its own lines first.
    if (existing.map((o) => o.discountPercent).toSet().length > 1) {
      for (final o in existing) {
        _flattenOrderDiscount(o);
      }
    }
    final siblings = <Order>[
      for (final o in existing)
        for (final id in o.linkedOrderUuids)
          if (!existing.any((e) => e.uuid == id)) ?orders.byUuid(id),
    ];
    final untouched = {
      for (final o in existing)
        o.uuid: o.lines.where((l) => !slices.containsKey(l.uuid)).toList(),
    };
    final made = <Order>[];
    for (var i = 0; i < existing.length; i++) {
      final o = existing[i];
      final keep = untouched[o.uuid]!;
      if (i >= groups.length && keep.isEmpty) {
        _detachFromSiblings(o);
        orders.delete(o.uuid);
        for (final e in [...existing, ...siblings]) {
          e.linkedOrderUuids.remove(o.uuid);
        }
        continue;
      }
      o.lines
        ..clear()
        ..addAll(i < groups.length ? groups[i] : const [])
        ..addAll(keep);
      _foldShares(o);
      orders.save(o);
      made.add(o);
    }
    for (final g in groups.skip(existing.length)) {
      final check = _tagged(
        Order(
          deviceId: deviceId,
          cashierId: cashierId,
          type: order.type,
          tableLabel: order.tableLabel,
          partnerId: order.partnerId,
          customerName: order.customerName,
          customerPhone: order.customerPhone,
          discountPercent: order.discountPercent,
          discountReason: order.discountReason,
          serviceChargePercent: order.serviceChargePercent,
          lines: g,
        ),
      )..state = OrderState.held;
      _stampOrderNo(check);
      orders.save(check);
      made.add(check);
    }
    for (final a in made) {
      for (final b in [...made, ...siblings]) {
        _linkPair(a, b);
      }
    }
    audit.record(cashierId, 'order.split_check',
        detail: '${order.uuid}|${made.length} checks');
    return made;
  }

  /// Join the shares of one item that ended up on the same check back into one
  /// line (half a pasta and its other half make the pasta again). Only a share
  /// (a fractional quantity) is joined; whole lines keep their own rows.
  void _foldShares(Order o) {
    for (var i = 0; i < o.lines.length; i++) {
      final a = o.lines[i];
      for (var j = o.lines.length - 1; j > i; j--) {
        final b = o.lines[j];
        final share = a.quantity != a.quantity.roundToDouble() ||
            b.quantity != b.quantity.roundToDouble();
        if (!share ||
            b.productId != a.productId ||
            b.name != a.name ||
            b.unitPrice != a.unitPrice ||
            b.taxRate != a.taxRate ||
            b.note != a.note ||
            b.discountPercent != a.discountPercent ||
            b.seat != a.seat ||
            b.printedToKitchen != a.printedToKitchen ||
            !_sameModifiers(a.modifiers, b.modifiers)) {
          continue;
        }
        a.quantity += b.quantity;
        if ((a.quantity - a.quantity.roundToDouble()).abs() < 1e-9) {
          a.quantity = a.quantity.roundToDouble();
        }
        o.lines.removeAt(j);
      }
    }
  }

  OrderLine _copyLine(OrderLine src, double quantity) => OrderLine(
        productId: src.productId,
        odooProductId: src.odooProductId,
        name: src.name,
        quantity: quantity,
        unitPrice: src.unitPrice,
        categoryId: src.categoryId,
        taxRate: src.taxRate,
        baseTaxRate: src.baseTaxRate,
        note: src.note,
        discountPercent: src.discountPercent,
        printedToKitchen: src.printedToKitchen,
        firedStations: List.of(src.firedStations),
        fireAt: src.fireAt,
        seat: src.seat,
        modifiers: [
          for (final m in src.modifiers)
            OrderModifier(
                modifierId: m.modifierId,
                productId: m.productId,
                name: m.name,
                quantity: m.quantity,
                unitPrice: m.unitPrice),
        ],
      );

  /// What a check made of [lines] is charged. [payCheck] books exactly this, so a
  /// tender sheet asks for this figure rather than re-deriving part of it and coming
  /// up short: it used to come up short by the service charge, and then by the tax.
  /// One helper on the bill now answers it for every partial-charge path.
  double checkTotal(Iterable<OrderLine> lines) => current.chargeFor(lines);

  /// Carve a subset of the current order's lines into their own paid check and
  /// take payment for it, leaving the rest of the table open. This is how a split
  /// bill is settled: each guest/selection becomes its own paid order that syncs on
  /// its own, so the server needs no concept of a split. Returns the paid check for
  /// printing. The order-level discount rides along (it is a percentage, so each
  /// check discounts only its own lines); tip is whatever was tendered on the check.
  /// The service percentage rides along the same way, taken from the table's stamp
  /// rather than read again, so the checks add up to exactly what the table was
  /// charged. Null when none of [lineUuids] are still on the table, which is what a
  /// second tap on the same check looks like.
  Order? payCheck(
    List<String> lineUuids, {
    List<OrderPayment> payments = const [],
    double? cashReceived,
    double tip = 0,
  }) {
    final order = current;
    final ids = lineUuids.toSet();
    final taken = order.lines.where((l) => ids.contains(l.uuid)).toList();
    if (taken.isEmpty) return null;
    final check =
        _tagged(
            Order(
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
              serviceChargePercent: order.serviceChargePercent,
              tip: tip,
              lines: taken,
            ),
          )
          ..state = OrderState.paid
          ..payments = List.of(payments)
          ..cashReceived = cashReceived;
    _stampSaleTime(check);
    // Its own number: a split check is its own paid sale, printed and reported on
    // its own, so it cannot share the table's.
    _stampOrderNo(check);
    _bookPaid(check, '${check.uuid}|split check');
    order.lines.removeWhere((l) => ids.contains(l.uuid));
    if (order.lines.isEmpty) {
      // Whole table settled: discard the now-empty running order and start fresh.
      _detachFromSiblings(order);
      orders.delete(order.uuid);
      _current = _blankOrder();
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
  ///
  /// The service charge belongs to the bill, not to the line, because it is a
  /// percentage of the bill the table is handed. A tab opened by this move therefore
  /// takes the source's percentage (the moved lines keep the price they were rung at);
  /// a tab that already exists keeps its own, and the lines joining it are serviced at
  /// that bill's rate. Both were stamped from the same shop setting, so they differ
  /// only if it was edited mid-service.
  Order moveLinesToTable(Set<String> lineUuids, String targetTableLabel,
      {String? targetOrderUuid}) {
    final order = current;
    // Moving onto the table the order is already on would fork a duplicate tab for
    // the same table, so it is a no-op unless the waiter named a specific other
    // bill already sitting there.
    if (targetTableLabel == order.tableLabel &&
        (targetOrderUuid == null || targetOrderUuid == order.uuid)) {
      return order;
    }
    if (tableBusyElsewhere(targetTableLabel)) return order;
    final taken = order.lines.where((l) => lineUuids.contains(l.uuid)).toList();
    if (taken.isEmpty || !canMoveLines(lineUuids)) return order;
    final whole = taken.length == order.lines.length;
    final joined = _tabToJoin(order, targetTableLabel, targetOrderUuid);
    if (whole && joined == null) return _relabel(order, targetTableLabel);
    _carryOrderDiscount(order.discountPercent, taken);
    final target =
        joined ??
        (_tagged(
          Order(
            deviceId: deviceId,
            cashierId: cashierId,
            type: OrderType.dineIn,
            tableLabel: targetTableLabel,
            serviceChargePercent: order.serviceChargePercent,
          ),
        )..state = OrderState.held);
    // Flatten the target's own discount to line level first, so the moved lines
    // (already priced) are not discounted a second time by it.
    _flattenOrderDiscount(target);
    target.lines.addAll(taken);
    if (whole) _carryMoney(order, target);
    orders.save(target);
    order.lines.removeWhere((l) => lineUuids.contains(l.uuid));
    audit.record(cashierId, 'order.moved',
        detail: '${order.uuid}->${target.uuid}|${taken.length} line(s)');
    if (order.lines.isEmpty) {
      _detachFromSiblings(order);
      orders.delete(order.uuid);
      _current = _blankOrder();
    } else {
      orders.save(order);
    }
    return target;
  }

  /// Whether another till holds a tab on [label]. Lines cannot be moved there from
  /// here: this till cannot write into a bill it does not own, and opening a second
  /// tab beside it is how one table ends up with two bills on two tills.
  bool tableBusyElsewhere(String label) => orders.occupyingAnywhere().any(
      (o) => o.tableLabel == label.trim() && o.deviceId != deviceId);

  /// Whether [lineUuids] may leave the current order. Money taken on a table was
  /// paid toward the whole bill, so part of a part-paid table cannot move without
  /// deciding which items that money bought: settle it, or move the whole table.
  bool canMoveLines(Set<String> lineUuids) =>
      current.payments.isEmpty ||
      current.lines.every((l) => lineUuids.contains(l.uuid));

  /// The open tab on [table] that moved lines join: the bill the waiter named if it
  /// is still there, else the first one sitting there, else null for an empty table.
  Order? _tabToJoin(Order from, String table, String? namedUuid) {
    if (namedUuid != null) {
      final named = orders.byUuid(namedUuid);
      if (named != null && named.tableLabel == table) return named;
    }
    for (final o in orders.held()) {
      if (o.tableLabel == table && o.uuid != from.uuid) return o;
    }
    return null;
  }

  /// A whole table moving to an empty one is the same bill at a new table, not a
  /// new bill: its number is already on the kitchen tickets, and the shares taken
  /// on it are already on the till. Only the table changes.
  Order _relabel(Order order, String table) {
    _detachFromSiblings(order);
    order
      ..tableLabel = table
      ..type = OrderType.dineIn
      ..state = OrderState.held;
    orders.save(order);
    audit.record(cashierId, 'order.moved', detail: '${order.uuid}->$table|whole table');
    _current = _blankOrder();
    return order;
  }

  /// Hand the money on a bill that is being folded away to the bill that absorbs
  /// it, so a share already paid is not charged again or lost from the drawer.
  static void _carryMoney(Order from, Order to) {
    to.payments = [...to.payments, ...from.payments];
    to.tip += from.tip;
    final cash = from.cashReceived;
    if (cash != null) to.cashReceived = (to.cashReceived ?? 0) + cash;
    to.partnerId ??= from.partnerId;
    if ((to.customerName ?? '').isEmpty) {
      to.customerName = from.customerName;
      to.customerPhone = from.customerPhone;
    }
  }

  /// Fold another table's open order into the current one, then discard the source.
  /// Used for "merge tables". A no-op if the source is missing or is this order. One
  /// merged bill carries one service percentage, so the surviving order keeps its own.
  void mergeOrderInto(String sourceUuid) {
    final source = orders.byUuid(sourceUuid);
    if (source == null || source.uuid == current.uuid) return;
    // Keep both tables' discounts with their own items: fold the source discount
    // into the incoming lines and flatten this table's discount onto its existing
    // lines, so neither set is discounted twice once they share one order.
    _carryOrderDiscount(source.discountPercent, source.lines);
    _flattenOrderDiscount(current);
    current.lines.addAll(source.lines);
    _carryMoney(source, current);
    orders.save(current);
    _detachFromSiblings(source);
    orders.delete(source.uuid);
    audit.record(cashierId, 'order.merged',
        detail: '${source.uuid}->${current.uuid}|${source.lines.length} line(s)');
  }

  /// Save a paid sale and queue it for Odoo and the owner mirror as one write.
  void _bookPaid(Order order, String detail) {
    orders.inTransaction(() {
      orders.save(order);
      _watchQueued(
          outbox.enqueue('order.push', order.uuid, order.toServerPayload()), order.uuid);
      _mirrorPaid(order);
    });
    audit.record(cashierId, 'order.paid', detail: detail);
  }

  /// Not awaited, because selling must not wait on anything, but not dropped
  /// either: a queue write that failed is a sale nothing will send, and the audit
  /// log is where the shop can see it.
  void _watchQueued(Future<void> queued, String uuid) {
    unawaited(queued.catchError((Object e) {
      audit.record(cashierId, 'outbox.enqueue.failed', detail: '$uuid: $e');
    }));
  }

  /// Queue the Dishflow owner mirror when configured. Fire-and-forget like
  /// order.push: the outbox append is durable and selling must not await a network.
  void _mirrorPaid(Order order) {
    final s = settings;
    if (s == null) return;
    _watchQueued(
        DishflowMirror.enqueueIfEnabled(outbox: outbox, settings: s, order: order),
        order.uuid);
    unawaited(_completeEcommerceIfLinked(order));
  }

  /// Soft-complete the store order so the customer app leaves "preparing".
  Future<void> _completeEcommerceIfLinked(Order order) async {
    final id = order.ecommerceOrderId?.trim();
    final s = settings;
    if (id == null || id.isEmpty || s == null || !s.dishflowMirrorReady) return;
    try {
      await EcommerceOrdersClient().markCompleted(
        projectId: s.dishflowProjectId!,
        apiKey: s.dishflowApiKey!,
        orderId: id,
      );
    } catch (e) {
      // The sale stands; only the customer's "preparing" screen is behind.
      audit.record(cashierId, 'ecommerce.complete.failed', detail: '$id: $e');
    }
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
