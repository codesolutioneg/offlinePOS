import '../orders.dart';

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
  final List<OwnerOrder> orders;
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
}

class FlashReportBuilder {
  FlashReportBuilder._();

  static FlashReportData build({
    required String title,
    required String periodLabel,
    required List<OwnerOrder> orders,
    String? filterLabel,
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

    // Same books as till Flash: drop full cancels + refund rows.
    orders = salesForReports(orders);
    for (final o in orders) {
      final total = o.total;
      gross += total;
      net += o.subtotal;
      tax += o.taxTotal;
      discounts += o.checkDiscount + o.lineDiscount;
      delivery += o.deliveryCost;
      tips += o.tip;

      final type =
          o.orderType.trim().isEmpty ? '—' : o.orderType.trim();
      byType[type] = (byType[type] ?? 0) + total;
      byCashier[o.cashierId] = (byCashier[o.cashierId] ?? 0) + total;
      final till = o.deviceId.isEmpty ? '—' : o.deviceId;
      byDevice[till] = (byDevice[till] ?? 0) + total;

      if (o.payments.isEmpty) {
        if (total.abs() >= 0.02) {
          byPay['Cash'] = (byPay['Cash'] ?? 0) + total;
        }
      } else {
        for (final p in o.payments) {
          if (p.amount.abs() < 0.02) continue;
          final k =
              (p.label ?? '').trim().isEmpty ? 'Cash' : p.label!.trim();
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

  static bool _isDelivery(OwnerOrder o) {
    final t = o.orderType.toLowerCase();
    return t.contains('deliver') || t.contains('توصيل');
  }

  static List<OwnerOrder> deliveryOnly(List<OwnerOrder> orders) =>
      orders.where(_isDelivery).toList();

  static List<OwnerOrder> withPayment(
      List<OwnerOrder> orders, String paymentLabel) {
    final want = paymentLabel.trim().toLowerCase();
    return orders.where((o) {
      if (o.payments.isEmpty) return want == 'cash';
      return o.payments
          .any((p) => (p.label ?? 'Cash').trim().toLowerCase() == want);
    }).toList();
  }

  static List<String> paymentLabels(List<OwnerOrder> orders) {
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
    return set.toList()..sort();
  }

  static List<String> cashierIds(List<OwnerOrder> orders) {
    final ids = orders.map((o) => o.cashierId).toSet().toList()..sort();
    return ids;
  }
}

/// Dishflow Flash SALES SUMMARY math (14% VAT inclusive).
class FlashSalesSummaryMath {
  const FlashSalesSummaryMath({
    required this.payments,
    required this.discounts,
  });

  static const taxFactor = 1.14;
  final double payments;
  final double discounts;

  double get salesPlusDiscount =>
      (payments + discounts).clamp(0.0, double.infinity);

  double get tax {
    final s = salesPlusDiscount;
    if (s <= 0.0001) return 0.0;
    return s - s / taxFactor;
  }

  double get total =>
      (salesPlusDiscount - discounts).clamp(0.0, double.infinity);

  double get amountSales =>
      (total + discounts - tax).clamp(0.0, double.infinity);
}
