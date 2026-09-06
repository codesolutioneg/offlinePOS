// Shared, pure aggregation for the restaurant report family (group sales, item
// sales, session detail, revenue centres, daily sales, discounts, refunds and
// the session summary).
//
// Everything here is a pure function over the order list the hub already
// windowed and filtered: no storage, no network, no clock. Every report builds
// on these helpers so they all reconcile to the same net, tax and total figures.
//
// COST CAVEAT: cost uses the CURRENT product cost from the catalogue, not the
// cost at the moment of sale. A cost edited in Odoo after a sale restates that
// sale's cost in these reports; the till never captured a cost onto the line.
//
// NET CAVEAT: "net" is the item subtotal (each line net of its own discount)
// BEFORE the whole-order discount. The order discount is not a sale, it is money
// given away, so it is reported apart (Discounts, and the summary's discount
// line) rather than folded into net. This is what lets a line-aggregated report
// (group/item sales) and an order-aggregated one (session detail, revenue
// centres, summary) agree to the cent.

import '../../domain/catalogue.dart';
import '../../domain/order.dart';

/// The label for a line whose category is missing or was deleted after the sale,
/// and for the super-type above such a category.
const String kUncategorised = 'Uncategorised';

/// The channels the daily-sales and revenue reports roll order types up into.
/// A sale has exactly one channel, so the channel sums always add to the total.
enum SalesChannel { tableService, takeAway, delivery }

extension SalesChannelLabel on SalesChannel {
  String get label => switch (this) {
        SalesChannel.tableService => 'Table Service',
        SalesChannel.takeAway => 'Take Away',
        SalesChannel.delivery => 'Delivery',
      };
}

/// Which channel a sale of [type] belongs to. To-go is bagged like a takeaway, so
/// it rolls up with take away rather than table service; delivery is its own; the
/// rest (dine-in) is table service.
SalesChannel channelFor(OrderType type) => switch (type) {
      OrderType.delivery => SalesChannel.delivery,
      OrderType.takeaway || OrderType.toGo => SalesChannel.takeAway,
      OrderType.dineIn => SalesChannel.tableService,
    };

// -- Per-order money, one definition every report shares -----------------------

/// The item net of a sale: the subtotal, each line already net of its own
/// discount, before the whole-order discount. Negative on a refund.
double orderNet(Order o) => o.subtotal;

/// The service charge money on a sale.
double orderService(Order o) => o.serviceCharge;

/// The VAT money on a sale.
double orderVat(Order o) => o.taxTotal;

/// What the session reports call "Taxes": the service charge plus the VAT, both
/// of which are charged on top of the net menu prices.
double orderTaxes(Order o) => o.serviceCharge + o.taxTotal;

/// What the customer actually paid: net less the order discount, plus taxes,
/// delivery and tip. Negative on a refund.
double orderTotal(Order o) => o.total;

/// The whole-order (check-level) discount in money, on the net scale. Distinct
/// from a line's own discount, which stays inside that line's net.
double orderCheckDiscount(Order o) => o.subtotal * o.discountPercent / 100;

/// A sale's per-line discounts in money (each line's gross times its own percent).
double orderLineDiscount(Order o) =>
    o.lines.fold(0.0, (s, l) => s + l.gross * l.discountPercent / 100);

/// The category "Type" (super-type) and "Group" a catalogue category resolves to.
/// A group's [Category.parentId] is its type; a top-level category is its own
/// type; a missing/unknown category falls into [kUncategorised] for both, so no
/// line is ever silently dropped from a total.
({String type, String group}) categoryPath(
    int? categoryId, Map<int, Category> byId) {
  final group = categoryId == null ? null : byId[categoryId];
  if (group == null) return (type: kUncategorised, group: kUncategorised);
  final parent = group.parentId == null ? null : byId[group.parentId];
  return (type: parent?.name ?? group.name, group: group.name);
}

// -- Group sales ---------------------------------------------------------------

/// One (Type, Group) tally: units moved, net sold and cost of goods.
class GroupSalesRow {
  GroupSalesRow({required this.type, required this.group});
  final String type;
  final String group;
  double qty = 0;
  double net = 0;
  double cost = 0;

  /// Cost as a share of net. Zero net has no percentage.
  double get costPercent => net == 0 ? 0 : cost / net * 100;
}

/// Every (Type, Group) sold across [orders], with the cost the catalogue holds.
List<GroupSalesRow> groupSales(
    List<Order> orders, List<Category> categories, Map<int, double> costs) {
  final byId = {for (final c in categories) c.id: c};
  final rows = <(String, String), GroupSalesRow>{};
  for (final o in orders) {
    for (final l in o.lines) {
      final path = categoryPath(l.categoryId, byId);
      final row = rows.putIfAbsent((path.type, path.group),
          () => GroupSalesRow(type: path.type, group: path.group));
      row.qty += l.quantity;
      row.net += l.total;
      row.cost += (costs[l.productId] ?? 0) * l.quantity;
    }
  }
  final out = rows.values.toList()
    ..sort((a, b) {
      final byType = a.type.compareTo(b.type);
      return byType != 0 ? byType : b.net.compareTo(a.net);
    });
  return out;
}

// -- Item sales ----------------------------------------------------------------

/// One item's tally inside its (Type, Group): units, net and cost of goods.
class ItemSalesRow {
  ItemSalesRow({
    required this.type,
    required this.group,
    required this.name,
  });
  final String type;
  final String group;
  final String name;
  double qty = 0;
  double net = 0;
  double cost = 0;

  double get costPercent => net == 0 ? 0 : cost / net * 100;
}

/// Every item sold across [orders], grouped under its (Type, Group).
List<ItemSalesRow> itemSales(
    List<Order> orders, List<Category> categories, Map<int, double> costs) {
  final byId = {for (final c in categories) c.id: c};
  final rows = <(String, String, String), ItemSalesRow>{};
  for (final o in orders) {
    for (final l in o.lines) {
      final path = categoryPath(l.categoryId, byId);
      final row = rows.putIfAbsent(
          (path.type, path.group, l.name),
          () => ItemSalesRow(type: path.type, group: path.group, name: l.name));
      row.qty += l.quantity;
      row.net += l.total;
      row.cost += (costs[l.productId] ?? 0) * l.quantity;
    }
  }
  final out = rows.values.toList()
    ..sort((a, b) {
      final byType = a.type.compareTo(b.type);
      if (byType != 0) return byType;
      final byGroup = a.group.compareTo(b.group);
      return byGroup != 0 ? byGroup : b.net.compareTo(a.net);
    });
  return out;
}

// -- Session detail (per-check ledger) -----------------------------------------

/// One tender against a check: its label and the money taken on it. A split
/// check produces several of these, summing to the check total.
class TenderLine {
  const TenderLine(this.label, this.amount);
  final String label;
  final double amount;
}

/// One check in the session-detail ledger.
class SessionCheck {
  SessionCheck({
    required this.order,
    required this.tenders,
  });
  final Order order;
  final List<TenderLine> tenders;

  double get subtotal => orderNet(order);
  double get taxes => orderTaxes(order);
  double get total => orderTotal(order);
  double get checkDiscount => orderCheckDiscount(order);
}

/// The tenders on a sale, as the session detail shows them. An order with no
/// recorded payment is an implicit cash sale for its whole total, matching how
/// the drawer and the server book it.
List<TenderLine> tendersOf(Order o, {String cashLabel = 'Cash'}) {
  if (o.payments.isEmpty) return [TenderLine(cashLabel, orderTotal(o))];
  return [for (final p in o.payments) TenderLine(p.label ?? cashLabel, p.amount)];
}

/// Every check in [orders], oldest first, as the per-check ledger.
List<SessionCheck> sessionChecks(List<Order> orders, {String cashLabel = 'Cash'}) {
  final out = [
    for (final o in orders)
      SessionCheck(order: o, tenders: tendersOf(o, cashLabel: cashLabel)),
  ]..sort((a, b) => a.order.createdAt.compareTo(b.order.createdAt));
  return out;
}

// -- Revenue centres -----------------------------------------------------------

/// One revenue centre (order type): transactions, covers and money. Refunds
/// reduce the money but are not counted as transactions or covers, so the
/// averages read against real sales.
class RevenueCentreRow {
  RevenueCentreRow(this.type);
  final OrderType type;
  int trans = 0;
  int covers = 0;
  double net = 0;
  double taxes = 0;
  double total = 0;

  double get transAvg => trans == 0 ? 0 : total / trans;
  double get customerAvg => covers == 0 ? 0 : total / covers;
}

/// Sales by revenue centre across [orders]. A refund's negative money folds into
/// the centre matching its order type so the centre net still reconciles with the
/// group/item totals, but the refund is excluded from the transaction and cover
/// counts so the averages are not skewed by money handed back.
List<RevenueCentreRow> revenueCentres(List<Order> orders) {
  final rows = <OrderType, RevenueCentreRow>{
    for (final t in OrderType.values) t: RevenueCentreRow(t),
  };
  for (final o in orders) {
    final row = rows[o.type]!;
    row.net += orderNet(o);
    row.taxes += orderTaxes(o);
    row.total += orderTotal(o);
    if (!o.isRefund) {
      row.trans += 1;
      row.covers += o.guestCount ?? 0;
    }
  }
  return [
    for (final t in OrderType.values)
      if (rows[t]!.trans != 0 || rows[t]!.total != 0) rows[t]!,
  ];
}

// -- Daily sales ---------------------------------------------------------------

/// One business day, split by channel plus the day's roll-up.
class DailySalesRow {
  DailySalesRow(this.day);
  final String day;

  /// Per channel: net sold and number of checks.
  final Map<SalesChannel, ({double net, int checks})> byChannel = {};

  int customers = 0;
  double net = 0;
  double totalInclTax = 0;

  double channelNet(SalesChannel c) => byChannel[c]?.net ?? 0;
  int channelChecks(SalesChannel c) => byChannel[c]?.checks ?? 0;
  double channelAvg(SalesChannel c) {
    final b = byChannel[c];
    return b == null || b.checks == 0 ? 0 : b.net / b.checks;
  }
}

/// Sales per business day across [orders], oldest day first. A refund folds into
/// its day and channel as negative money but is not counted as a check or cover.
List<DailySalesRow> dailySales(List<Order> orders) {
  final rows = <String, DailySalesRow>{};
  for (final o in orders) {
    final day = o.businessDay.key;
    final row = rows.putIfAbsent(day, () => DailySalesRow(day));
    final channel = channelFor(o.type);
    final prev = row.byChannel[channel] ?? (net: 0.0, checks: 0);
    row.byChannel[channel] = (
      net: prev.net + orderNet(o),
      checks: prev.checks + (o.isRefund ? 0 : 1),
    );
    row.net += orderNet(o);
    row.totalInclTax += orderTotal(o);
    if (!o.isRefund) row.customers += o.guestCount ?? 0;
  }
  return rows.values.toList()..sort((a, b) => a.day.compareTo(b.day));
}

// -- Detailed discounts --------------------------------------------------------

/// Whether a discount row is a whole-check discount or one line's own.
enum DiscountLevel { check, line }

/// One discounted line, or one order-level (check) discount.
class DiscountDetailRow {
  DiscountDetailRow({
    required this.order,
    required this.level,
    required this.item,
    required this.qty,
    required this.rawPrice,
    required this.chargedPrice,
    required this.reason,
  });
  final Order order;
  final DiscountLevel level;
  final String item;
  final double qty;
  final double rawPrice;
  final double chargedPrice;
  final String reason;

  double get difference => rawPrice - chargedPrice;
}

/// Every discount given across [orders]: one row per discounted line and one per
/// order-level discount. Raw is the price before the discount, charged is after.
List<DiscountDetailRow> discountDetails(List<Order> orders) {
  final out = <DiscountDetailRow>[];
  for (final o in orders) {
    for (final l in o.lines) {
      if (l.discountPercent <= 0) continue;
      out.add(DiscountDetailRow(
        order: o,
        level: DiscountLevel.line,
        item: l.name,
        qty: l.quantity,
        rawPrice: l.gross,
        chargedPrice: l.total,
        reason: (o.discountReason?.trim().isNotEmpty ?? false)
            ? o.discountReason!.trim()
            : 'Line discount',
      ));
    }
    if (o.discountPercent > 0) {
      out.add(DiscountDetailRow(
        order: o,
        level: DiscountLevel.check,
        item: 'Whole check',
        qty: 1,
        rawPrice: o.subtotal,
        chargedPrice: o.subtotal * o.discountFactor,
        reason: (o.discountReason?.trim().isNotEmpty ?? false)
            ? o.discountReason!.trim()
            : 'No reason',
      ));
    }
  }
  out.sort((a, b) => a.order.createdAt.compareTo(b.order.createdAt));
  return out;
}

// -- Refunds -------------------------------------------------------------------

/// The refunds in [orders] summarised: how many, and the money handed back, all
/// as positive figures a manager reads as "refunded".
class RefundSummary {
  const RefundSummary({
    required this.count,
    required this.net,
    required this.taxes,
    required this.total,
  });
  final int count;
  final double net;
  final double taxes;
  final double total;
}

/// Summarise the refunds in [orders]. Zeros when there are none, like the real
/// report, rather than an empty page.
RefundSummary refundSummary(List<Order> orders) {
  final refunds = orders.where((o) => o.isRefund);
  return RefundSummary(
    count: refunds.length,
    net: refunds.fold(0.0, (s, o) => s + orderNet(o)).abs(),
    taxes: refunds.fold(0.0, (s, o) => s + orderTaxes(o)).abs(),
    total: refunds.fold(0.0, (s, o) => s + orderTotal(o)).abs(),
  );
}

// -- Totals every report footers off ------------------------------------------

/// The reconciling totals shared by every restaurant report: net, taxes and
/// total over the whole order list (refunds included as negatives), plus the
/// cost of goods and the giveaways reported apart from net.
class ReportTotals {
  const ReportTotals({
    required this.net,
    required this.service,
    required this.vat,
    required this.total,
    required this.cost,
    required this.checkDiscount,
    required this.lineDiscount,
    required this.refunds,
    required this.trans,
    required this.covers,
  });

  final double net;
  final double service;
  final double vat;
  final double total;

  /// Cost of goods over costed lines only (a line with no known cost adds 0).
  final double cost;
  final double checkDiscount;
  final double lineDiscount;

  /// Refunded money as a positive figure.
  final double refunds;

  /// Non-refund transactions and covers.
  final int trans;
  final int covers;

  double get taxes => service + vat;
  double get discount => checkDiscount + lineDiscount;
  double get grossProfit => net - cost;
  double get marginPercent => net == 0 ? 0 : grossProfit / net * 100;
  double get costPercent => net == 0 ? 0 : cost / net * 100;
  double get avgCheck => trans == 0 ? 0 : total / trans;
  double get avgCustomer => covers == 0 ? 0 : total / covers;
}

/// The reconciling totals across [orders], costed against [costs].
ReportTotals reportTotals(List<Order> orders, Map<int, double> costs) {
  var net = 0.0, service = 0.0, vat = 0.0, total = 0.0, cost = 0.0;
  var checkDiscount = 0.0, lineDiscount = 0.0, refunds = 0.0;
  var trans = 0, covers = 0;
  for (final o in orders) {
    net += orderNet(o);
    service += orderService(o);
    vat += orderVat(o);
    total += orderTotal(o);
    checkDiscount += orderCheckDiscount(o);
    lineDiscount += orderLineDiscount(o);
    for (final l in o.lines) {
      cost += (costs[l.productId] ?? 0) * l.quantity;
    }
    if (o.isRefund) {
      refunds += orderTotal(o).abs();
    } else {
      trans += 1;
      covers += o.guestCount ?? 0;
    }
  }
  return ReportTotals(
    net: net,
    service: service,
    vat: vat,
    total: total,
    cost: cost,
    checkDiscount: checkDiscount,
    lineDiscount: lineDiscount,
    refunds: refunds,
    trans: trans,
    covers: covers,
  );
}

/// Payment types across [orders], by tender label, matching the payment-mix
/// report and the drawer's tender split. An order with no payment is cash.
Map<String, double> paymentTypes(List<Order> orders, {String cashLabel = 'Cash'}) {
  final mix = <String, double>{};
  for (final o in orders) {
    for (final t in tendersOf(o, cashLabel: cashLabel)) {
      mix[t.label] = (mix[t.label] ?? 0) + t.amount;
    }
  }
  return mix;
}

/// Net sold per category Type (super-type) across [orders], biggest first.
Map<String, double> netByType(List<Order> orders, List<Category> categories) {
  final byId = {for (final c in categories) c.id: c};
  final out = <String, double>{};
  for (final o in orders) {
    for (final l in o.lines) {
      final type = categoryPath(l.categoryId, byId).type;
      out[type] = (out[type] ?? 0) + l.total;
    }
  }
  final entries = out.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return {for (final e in entries) e.key: e.value};
}
