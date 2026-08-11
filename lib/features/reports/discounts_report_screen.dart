import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../domain/order.dart';

/// One row in the reason breakdown: how many orders cited this reason and how
/// much discount they gave away, so a manager can see whether "staff meal" or
/// "complaint" is the thing actually eating into margin.
class _ReasonAggregate {
  _ReasonAggregate(this.reason);
  final String reason;
  int orderCount = 0;
  double amount = 0;
}

/// A read-only report on discounting: how much was given away, and why. It is
/// computed entirely from the orders handed in, never touching the database or
/// the network, so the caller decides the date range and this stays a pure view.
class DiscountsReportScreen extends StatelessWidget {
  const DiscountsReportScreen({super.key, required this.orders, required this.formatAmount});

  final List<Order> orders;
  final String Function(double) formatAmount;

  /// The whole-order discount, applied to the line subtotal (never to delivery
  /// or tip, which are never discounted).
  double _orderDiscount(Order o) => o.subtotal * o.discountPercent / 100;

  double get _totalOrderDiscount =>
      orders.fold(0.0, (s, o) => s + _orderDiscount(o));

  /// Per-line discounts are independent of the whole-order discount: each line
  /// is knocked down off its own gross before the order-level percentage is
  /// applied on top, so the two totals are summed rather than nested.
  double get _totalLineDiscount => orders.fold(
        0.0,
        (s, o) => s +
            o.lines.fold(0.0, (ls, l) => ls + l.gross * l.discountPercent / 100),
      );

  double get _grandTotal => _totalOrderDiscount + _totalLineDiscount;

  int get _discountedOrderCount =>
      orders.where((o) => o.discountPercent > 0).length;

  bool get _hasDiscounts => _grandTotal > 0;

  /// Groups the whole-order discount amount by [Order.discountReason],
  /// falling back to 'No reason' when a discount was given without one being
  /// recorded. Only orders with an actual discount are counted, since a 0%
  /// order with a stray reason string gives away nothing. Sorted by amount
  /// descending so the costliest reason is on top.
  List<_ReasonAggregate> _byReason() {
    final byReason = <String, _ReasonAggregate>{};
    for (final o in orders) {
      if (o.discountPercent <= 0) continue;
      final reason = o.discountReason?.trim();
      final key = (reason == null || reason.isEmpty) ? 'No reason' : reason;
      final agg = byReason.putIfAbsent(key, () => _ReasonAggregate(key));
      agg.orderCount += 1;
      agg.amount += _orderDiscount(o);
    }
    final list = byReason.values.toList()
      ..sort((a, b) => b.amount.compareTo(a.amount));
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
    if (!_hasDiscounts) {
      return Scaffold(
        appBar: AppBar(title: Text(tr(context, 'Discounts'))),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              key: const Key('discounts-empty-state'),
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.local_offer_outlined, size: 48, color: Theme.of(context).colorScheme.outline),
                const SizedBox(height: 12),
                Text(
                  tr(context, 'No discounts given'),
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 4),
                Text(
                  tr(context, 'Nothing was discounted in this range.'),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }

    final reasons = _byReason();

    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Discounts'))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _sectionCard(tr(context, 'Overview'), [
            _row(tr(context, 'Orders'), '${orders.length}'),
            _row(tr(context, 'Discounted orders'), '$_discountedOrderCount'),
            _row(tr(context, 'Total discount given'), formatAmount(_grandTotal), bold: true),
            _row(tr(context, 'Order-level discounts'), formatAmount(_totalOrderDiscount)),
            _row(tr(context, 'Line-level discounts'), formatAmount(_totalLineDiscount)),
          ]),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr(context, 'By reason'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const Divider(),
                if (reasons.isEmpty)
                  Text(tr(context, 'No order-level discounts'))
                else
                  // Bounded height nested inside the outer scroll view, so a long
                  // list of reasons doesn't need its own separate scroll gesture.
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: reasons.length * 56.0),
                    child: ListView.builder(
                      key: const Key('discount-reasons-list'),
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: reasons.length,
                      itemBuilder: (context, i) {
                        final r = reasons[i];
                        return ListTile(
                          dense: true,
                          title: Text(r.reason),
                          subtitle: Text('${r.orderCount} order${r.orderCount == 1 ? '' : 's'}'),
                          trailing: Text(formatAmount(r.amount)),
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
