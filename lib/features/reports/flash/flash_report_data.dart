import '../../../domain/order.dart';
import '../restaurant_analytics.dart';

/// One Flash report built from shop-wide paid/synced orders (LAN replicas included).
///
/// Dishflow reads Firebase `sales`. Offline POS reads SQLite via
/// [OrderStore.recentAnywhere] so every till on the fabric sees the same day
/// without waiting for the cloud.
class FlashReportData {
  const FlashReportData({
    required this.title,
    required this.periodLabel,
    required this.orders,
    required this.byPaymentMethod,
    required this.byOrderType,
    required this.byCashier,
    required this.byDevice,
    required this.grossTotal,
    required this.netSales,
    required this.taxTotal,
    required this.discountTotal,
    required this.deliveryTotal,
    required this.tipTotal,
    this.filterLabel,
  });

  final String title;
  final String periodLabel;
  final List<Order> orders;
  final Map<String, double> byPaymentMethod;
  final Map<String, double> byOrderType;
  final Map<String, double> byCashier;
  final Map<String, double> byDevice;
  final double grossTotal;
  final double netSales;
  final double taxTotal;
  final double discountTotal;
  final double deliveryTotal;
  final double tipTotal;
  final String? filterLabel;

  int get ordersCount => orders.length;

  /// Receipt / dialog rows: label → value.
  List<(String, String)> rows(String Function(double) money) => [
        if (filterLabel != null && filterLabel!.isNotEmpty)
          ('Filter', filterLabel!),
        ('Orders', '$ordersCount'),
        ('Net sales', money(netSales)),
        ('Discounts', money(discountTotal)),
        ('Tax (VAT)', money(taxTotal)),
        ('Delivery', money(deliveryTotal)),
        if (tipTotal.abs() > 0.004) ('Tips', money(tipTotal)),
        ('Total', money(grossTotal)),
        ('', ''),
        ('— Payments —', ''),
        for (final e in byPaymentMethod.entries) (e.key, money(e.value)),
        if (byOrderType.length > 1) ...[
          ('', ''),
          ('— By type —', ''),
          for (final e in byOrderType.entries) (e.key, money(e.value)),
        ],
        if (byCashier.length > 1) ...[
          ('', ''),
          ('— By cashier —', ''),
          for (final e in byCashier.entries) (e.key, money(e.value)),
        ],
        if (byDevice.length > 1) ...[
          ('', ''),
          ('— By till —', ''),
          for (final e in byDevice.entries) (e.key, money(e.value)),
        ],
      ];

  /// Thermal-safe rows: no blank pairs; section titles are markers starting with —.
  List<(String, String)> thermalRows(String Function(double) money) => [
        for (final r in rows(money))
          if (r.$1.isNotEmpty || r.$2.isNotEmpty) r,
      ];
}

/// Builds a [FlashReportData] from already windowed shop orders.
class FlashReportBuilder {
  FlashReportBuilder._();

  static FlashReportData build({
    required String title,
    required String periodLabel,
    required List<Order> orders,
    String? filterLabel,
    String Function(String cashierId)? cashierName,
    String Function(String deviceId)? deviceName,
  }) {
    final byPay = <String, double>{};
    final byType = <String, double>{};
    final byCashier = <String, double>{};
    final byDevice = <String, double>{};
    var gross = 0.0;
    var net = 0.0;
    var tax = 0.0;
    var discounts = 0.0;
    var delivery = 0.0;
    var tips = 0.0;

    for (final o in orders) {
      if (o.isRefund) continue;
      final total = o.total;
      gross += total;
      net += orderNet(o);
      tax += orderVat(o);
      discounts += orderCheckDiscount(o) + orderLineDiscount(o);
      delivery += o.deliveryCost;
      tips += o.tip;

      byType[o.type.label] = (byType[o.type.label] ?? 0) + total;

      final who = cashierName?.call(o.cashierId) ?? o.cashierId;
      byCashier[who] = (byCashier[who] ?? 0) + total;

      final till = deviceName?.call(o.deviceId) ?? o.deviceId;
      byDevice[till] = (byDevice[till] ?? 0) + total;

      if (o.payments.isEmpty) {
        byPay['Cash'] = (byPay['Cash'] ?? 0) + total;
      } else {
        for (final p in o.payments) {
          final k = (p.label ?? '').trim().isEmpty ? 'Cash' : p.label!.trim();
          byPay[k] = (byPay[k] ?? 0) + p.amount;
        }
      }
    }

    Map<String, double> sorted(Map<String, double> m) {
      final entries = m.entries.toList()
        ..sort((a, b) {
          final c = b.value.compareTo(a.value);
          return c != 0 ? c : a.key.compareTo(b.key);
        });
      return {for (final e in entries) e.key: e.value};
    }

    return FlashReportData(
      title: title,
      periodLabel: periodLabel,
      orders: List.unmodifiable(orders),
      byPaymentMethod: sorted(byPay),
      byOrderType: sorted(byType),
      byCashier: sorted(byCashier),
      byDevice: sorted(byDevice),
      grossTotal: gross,
      netSales: net,
      taxTotal: tax,
      discountTotal: discounts,
      deliveryTotal: delivery,
      tipTotal: tips,
      filterLabel: filterLabel,
    );
  }

  /// Delivery channels only (company / store / car).
  static List<Order> deliveryOnly(List<Order> orders) =>
      orders.where((o) => o.type.isDelivery).toList();

  /// Orders that used [paymentLabel] (case-insensitive match on tender label).
  static List<Order> withPayment(List<Order> orders, String paymentLabel) {
    final want = paymentLabel.trim().toLowerCase();
    return orders.where((o) {
      if (o.payments.isEmpty) return want == 'cash';
      return o.payments.any((p) => (p.label ?? 'Cash').trim().toLowerCase() == want);
    }).toList();
  }

  /// Distinct payment labels present in [orders].
  static List<String> paymentLabels(List<Order> orders) {
    final set = <String>{};
    for (final o in orders) {
      if (o.payments.isEmpty) {
        set.add('Cash');
      } else {
        for (final p in o.payments) {
          final k = (p.label ?? '').trim();
          set.add(k.isEmpty ? 'Cash' : k);
        }
      }
    }
    final list = set.toList()..sort();
    return list;
  }

  static List<String> cashierIds(List<Order> orders) {
    final ids = orders.map((o) => o.cashierId).toSet().toList()..sort();
    return ids;
  }
}
