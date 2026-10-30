// Lightweight order view for owner mobile — aligned with website home KPIs.

class OwnerModifier {
  const OwnerModifier({
    required this.name,
    required this.quantity,
    required this.unitPrice,
    this.productId,
  });
  final String name;
  final double quantity;
  final double unitPrice;
  final int? productId;

  double get total => quantity * unitPrice;

  factory OwnerModifier.fromJson(Map<String, dynamic> m) => OwnerModifier(
        name: '${m['name'] ?? ''}',
        quantity: (m['quantity'] as num?)?.toDouble() ?? 0,
        unitPrice: (m['unit_price'] as num?)?.toDouble() ?? 0,
        productId: (m['product_id'] as num?)?.toInt(),
      );
}

class OwnerOrderLine {
  const OwnerOrderLine({
    required this.productId,
    required this.name,
    required this.quantity,
    required this.unitPrice,
    this.discountPercent = 0,
    this.taxRate = 0,
    this.modifiers = const [],
  });

  final int productId;
  final String name;
  final double quantity;
  final double unitPrice;
  final double discountPercent;
  final double taxRate;
  final List<OwnerModifier> modifiers;

  double get gross => quantity * unitPrice;
  double get total => gross * (1 - discountPercent.clamp(0, 100) / 100);

  factory OwnerOrderLine.fromJson(Map<String, dynamic> m) => OwnerOrderLine(
        productId: (m['product_id'] as num?)?.toInt() ?? 0,
        name: '${m['name'] ?? ''}',
        quantity: (m['quantity'] as num?)?.toDouble() ?? 0,
        unitPrice: (m['unit_price'] as num?)?.toDouble() ?? 0,
        discountPercent: (m['discount_percent'] as num?)?.toDouble() ?? 0,
        taxRate: (m['tax_rate'] as num?)?.toDouble() ?? 0,
        modifiers: [
          for (final mod in (m['modifiers'] as List? ?? const []))
            if (mod is Map)
              OwnerModifier.fromJson(mod.cast<String, dynamic>()),
        ],
      );
}

class OwnerOrderPayment {
  const OwnerOrderPayment({
    required this.amount,
    this.label,
    this.methodId = 0,
  });
  final double amount;
  final String? label;
  final int methodId;

  factory OwnerOrderPayment.fromJson(Map<String, dynamic> m) =>
      OwnerOrderPayment(
        amount: (m['amount'] as num?)?.toDouble() ?? 0,
        label: m['label'] as String?,
        methodId: (m['method_id'] as num?)?.toInt() ?? 0,
      );
}

class OwnerOrder {
  const OwnerOrder({
    required this.uuid,
    required this.state,
    required this.createdAt,
    required this.cashierId,
    required this.orderType,
    required this.lines,
    required this.payments,
    this.orderNo,
    this.tableLabel,
    this.customerName,
    this.discountPercent = 0,
    this.discountReason,
    this.tip = 0,
    this.deliveryCost = 0,
    this.serviceChargePercent = 0,
    this.serviceFee = 0,
    this.guestCount,
    this.branchId = '',
    this.deviceId = '',
    this.refundOfUuid,
    this.driverName,
  });

  final String uuid;
  final String state;
  final DateTime createdAt;
  final String cashierId;
  final String orderType;
  final List<OwnerOrderLine> lines;
  final List<OwnerOrderPayment> payments;
  final String? orderNo;
  final String? tableLabel;
  final String? customerName;
  final double discountPercent;
  final String? discountReason;
  final double tip;
  final double deliveryCost;
  final double serviceChargePercent;
  final double serviceFee;
  final int? guestCount;
  final String branchId;
  final String deviceId;
  final String? refundOfUuid;
  final String? driverName;

  bool get isOpen => state == 'draft' || state == 'held';
  bool get isCompleted => state == 'paid' || state == 'synced';

  /// Same rule as the till domain: a refund names the original check.
  bool get isRefund =>
      refundOfUuid != null ||
      lines.any((l) => l.quantity < 0) ||
      (orderNo ?? '').startsWith('R');

  String get displayNo =>
      (orderNo ?? '').trim().isNotEmpty ? orderNo! : uuid.substring(0, 8);

  double get subtotal => lines.fold(0.0, (s, l) => s + l.total);

  double get discountFactor => 1 - discountPercent.clamp(0, 100) / 100;

  double get checkDiscount => subtotal * (1 - discountFactor);

  double get lineDiscount =>
      lines.fold(0.0, (s, l) => s + l.gross * l.discountPercent / 100);

  double get serviceChargeFactor =>
      1 + serviceChargePercent.clamp(0, 100) / 100;

  double get serviceCharge =>
      subtotal * discountFactor * serviceChargePercent.clamp(0, 100) / 100;

  /// Tax on lines × service (not after check discount) — same basis as the till.
  double get taxTotal {
    var t = 0.0;
    final s = serviceChargeFactor;
    for (final l in lines) {
      if (l.taxRate <= 0) continue;
      t += l.total * s * l.taxRate / 100;
    }
    return t;
  }

  /// What the customer pays — matches website home `Order.total`.
  double get total =>
      subtotal * discountFactor +
      serviceCharge +
      serviceFee +
      taxTotal +
      deliveryCost +
      tip;

  double costOf(Map<int, double> costs) => lines.fold(
      0.0, (s, l) => s + (costs[l.productId] ?? 0) * l.quantity);

  factory OwnerOrder.fromRecord(Map<String, Object?> p, {String branchId = ''}) {
    final m = p.cast<String, dynamic>();
    return OwnerOrder(
      uuid: '${m['uuid'] ?? ''}',
      state: '${m['state'] ?? ''}',
      createdAt: DateTime.tryParse('${m['created_at'] ?? ''}')?.toUtc() ??
          DateTime.now().toUtc(),
      cashierId: '${m['cashier_id'] ?? ''}',
      orderType: '${m['order_type'] ?? ''}',
      orderNo: m['order_no'] as String?,
      tableLabel: m['table_label'] as String?,
      customerName: m['customer_name'] as String?,
      discountPercent: (m['discount_percent'] as num?)?.toDouble() ?? 0,
      discountReason: m['discount_reason'] as String?,
      tip: (m['tip'] as num?)?.toDouble() ?? 0,
      deliveryCost: (m['delivery_cost'] as num?)?.toDouble() ?? 0,
      serviceChargePercent:
          (m['service_charge_percent'] as num?)?.toDouble() ?? 0,
      serviceFee: (m['service_fee'] as num?)?.toDouble() ?? 0,
      guestCount: (m['guest_count'] as num?)?.toInt(),
      branchId: branchId,
      deviceId: '${m['device_id'] ?? ''}',
      refundOfUuid: m['refund_of_uuid'] as String?,
      driverName: (m['driver_name'] as String?) ??
          (m['driverName'] as String?),
      lines: [
        for (final l in (m['lines'] as List? ?? const []))
          if (l is Map) OwnerOrderLine.fromJson(l.cast<String, dynamic>()),
      ],
      payments: [
        for (final pay in (m['payments'] as List? ?? const []))
          if (pay is Map)
            OwnerOrderPayment.fromJson(pay.cast<String, dynamic>()),
      ],
    );
  }
}

class PeriodKpis {
  const PeriodKpis({
    required this.netSales,
    required this.orders,
    required this.avgCheck,
    required this.refunds,
    required this.cost,
  });

  final double netSales;
  final int orders;
  final double avgCheck;
  final double refunds;
  final double cost;

  double get margin => netSales - cost;
}

/// Drop full cancel pairs (sale + matching refund that net to ~0).
List<OwnerOrder> withoutFullyCancelled(List<OwnerOrder> orders) {
  final refundNet = <String, double>{};
  for (final o in orders) {
    final of = o.refundOfUuid;
    if (of == null) continue;
    refundNet[of] = (refundNet[of] ?? 0) + o.total;
  }
  final cancelled = <String>{};
  for (final o in orders) {
    if (o.isRefund) continue;
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

/// Paid tickets for sales KPIs: no full cancels, no refund rows (website home).
List<OwnerOrder> salesForReports(List<OwnerOrder> orders) => [
      for (final o in withoutFullyCancelled(orders))
        if (!o.isRefund) o,
    ];

/// Line subtotal helper for cost / item reports.
double orderNet(OwnerOrder o) => o.subtotal;

/// Matches website home `_Stats.of`: sales = Σ `Order.total` after cancel pairs.
PeriodKpis computeKpis(List<OwnerOrder> all, Map<int, double> costs) {
  final completed = all.where((o) => o.isCompleted).toList();

  var net = 0.0;
  var cost = 0.0;
  var salesCount = 0;
  for (final o in salesForReports(completed)) {
    net += o.total;
    salesCount += 1;
    cost += o.costOf(costs);
  }

  var refunds = 0.0;
  for (final o in withoutFullyCancelled(completed)) {
    if (o.isRefund || o.total < 0) refunds += o.total.abs();
  }

  return PeriodKpis(
    netSales: net,
    orders: salesCount,
    avgCheck: salesCount == 0 ? 0 : net / salesCount,
    refunds: refunds,
    cost: cost,
  );
}

Map<int, double> costsFromRecords(Iterable<Map<String, Object?>> payloads) {
  final out = <int, double>{};
  void take(Map map) {
    for (final e in map.entries) {
      final id = int.tryParse('${e.key}');
      final v = e.value;
      if (id != null && v is num) out[id] = v.toDouble();
    }
  }

  for (final p in payloads) {
    final items = p['items'];
    if (items is Map) {
      take(items);
    } else {
      take({
        for (final e in p.entries)
          if (e.key != 'items' && int.tryParse(e.key) != null) e.key: e.value,
      });
    }
  }
  return out;
}

/// Calendar midnights for the period, exclusive [to] — same as website `_window`.
(DateTime, DateTime) periodWindow(String key, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final tomorrow = today.add(const Duration(days: 1));
  return switch (key) {
    'yesterday' => (today.subtract(const Duration(days: 1)), today),
    'last7' => (today.subtract(const Duration(days: 6)), tomorrow),
    _ => (today, tomorrow),
  };
}

String money(double v) => v.toStringAsFixed(2);
