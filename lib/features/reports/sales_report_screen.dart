import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../domain/order.dart';

/// One row in the item-sales table: a product's aggregated quantity and
/// revenue across every order passed to the screen.
class _ItemAggregate {
  _ItemAggregate(this.name);
  final String name;
  double quantity = 0;
  double revenue = 0;
}

/// A read-only end-of-shift/end-of-day report, computed entirely from the
/// orders already on the till. It never touches the database or the network
/// itself: the caller decides what "today" or "this shift" means and hands
/// in the finished order list, so the report stays a pure view.
class SalesReportScreen extends StatelessWidget {
  const SalesReportScreen({
    super.key,
    required this.orders,
    required this.formatAmount,
  });

  final List<Order> orders;
  final String Function(double) formatAmount;

  double get _grossSales => orders.fold(0.0, (s, o) => s + o.total);

  /// The whole-order discount is a percentage of the line subtotal, not of
  /// the final total, because delivery and tip are never discounted.
  double get _totalDiscounts =>
      orders.fold(0.0, (s, o) => s + o.subtotal * o.discountPercent / 100);

  double get _deliveryIncome => orders.fold(0.0, (s, o) => s + o.deliveryCost);

  double get _totalTips => orders.fold(0.0, (s, o) => s + o.tip);

  /// Counts and totals per [OrderType], in enum order so the report reads the
  /// same every time rather than shuffling with insertion order.
  Map<OrderType, ({int count, double total})> get _byType {
    final counts = <OrderType, int>{};
    final totals = <OrderType, double>{};
    for (final o in orders) {
      counts[o.type] = (counts[o.type] ?? 0) + 1;
      totals[o.type] = (totals[o.type] ?? 0) + o.total;
    }
    return {
      for (final t in OrderType.values)
        if (counts.containsKey(t)) t: (count: counts[t]!, total: totals[t]!),
    };
  }

  /// Groups every payment by its label, falling back to 'Cash' when a
  /// payment carries no label. A null label means the server would book it
  /// to cash, so the report shows the same thing the drawer will.
  Map<String, double> _paymentMix(BuildContext context) {
    final mix = <String, double>{};
    for (final o in orders) {
      for (final p in o.payments) {
        final label = p.label ?? tr(context, 'Cash');
        mix[label] = (mix[label] ?? 0) + p.amount;
      }
    }
    return mix;
  }

  /// Aggregates every line across every order by product name, since two
  /// lines for the same product across different orders are still one row
  /// on a sales report. Sorted by revenue so the top seller is on top.
  List<_ItemAggregate> _itemSales() {
    final byName = <String, _ItemAggregate>{};
    for (final o in orders) {
      for (final l in o.lines) {
        final agg = byName.putIfAbsent(l.name, () => _ItemAggregate(l.name));
        agg.quantity += l.quantity;
        agg.revenue += l.total;
      }
    }
    final list = byName.values.toList()
      ..sort((a, b) => b.revenue.compareTo(a.revenue));
    return list;
  }

  Widget _row(String k, String v, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Text(k),
          const Spacer(),
          Text(v, style: TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
        ]),
      );

  Widget _sectionCard(String title, List<Widget> children) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const Divider(),
            ...children,
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final byType = _byType;
    final paymentMix = _paymentMix(context);
    final itemSales = _itemSales();

    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Sales report'))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _sectionCard(tr(context, 'Overview'), [
            _row(tr(context, 'Orders'), '${orders.length}'),
            _row(tr(context, 'Gross sales'), formatAmount(_grossSales), bold: true),
            _row(tr(context, 'Discounts given'), formatAmount(_totalDiscounts)),
            _row(tr(context, 'Delivery income'), formatAmount(_deliveryIncome)),
            _row(tr(context, 'Tips'), formatAmount(_totalTips)),
          ]),
          _sectionCard(
            tr(context, 'Sales by order type'),
            byType.isEmpty
                ? [Text(tr(context, 'No orders'))]
                : byType.entries
                    .map((e) => _row(
                          '${e.key.label} (${e.value.count})',
                          formatAmount(e.value.total),
                        ))
                    .toList(),
          ),
          _sectionCard(
            tr(context, 'Payment mix'),
            paymentMix.isEmpty
                ? [Text(tr(context, 'No payments'))]
                : paymentMix.entries
                    .map((e) => _row(e.key, formatAmount(e.value)))
                    .toList(),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr(context, 'Item sales'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const Divider(),
                if (itemSales.isEmpty)
                  Text(tr(context, 'No items sold'))
                else
                  // Bounded height list nested inside the outer scroll view, so a
                  // long menu doesn't need its own separate scroll gesture.
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: itemSales.length * 48.0),
                    child: ListView.builder(
                      key: const Key('item-sales-list'),
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: itemSales.length,
                      itemBuilder: (context, i) {
                        final item = itemSales[i];
                        final qty = item.quantity == item.quantity.roundToDouble()
                            ? item.quantity.toStringAsFixed(0)
                            : item.quantity.toString();
                        return ListTile(
                          dense: true,
                          title: Text('$qty x ${item.name}'),
                          trailing: Text(formatAmount(item.revenue)),
                        );
                      },
                    ),
                  ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
