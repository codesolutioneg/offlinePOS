import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../domain/order.dart';

/// One payment method's tally across the report window: how many tenders
/// landed on it and how much money moved through it.
///
/// Aggregated by label rather than [OrderPayment.methodId], since two orders
/// paid on the same method still share the label a manager reads on the
/// printed report, and an order with no recorded payment is booked to cash
/// for its whole total, not skipped.
class _MethodAggregate {
  _MethodAggregate({required this.label, required this.count, required this.amount});
  final String label;
  final int count;
  final double amount;
}

/// A payment-mix report: how customers paid, by method.
///
/// An order can carry zero, one, or several [OrderPayment] entries (a split
/// tender). Zero entries is not "unpaid" here: the sale still has a [Order.total]
/// and the server books an unrecorded tender to cash, so this report must do
/// the same or the grand total would fall short of the sum of every order.
class PaymentAnalysisReportScreen extends StatelessWidget {
  const PaymentAnalysisReportScreen({super.key, required this.orders, required this.formatAmount});
  final List<Order> orders;
  final String Function(double) formatAmount;

  static const String _cashFallbackLabel = 'Cash';

  /// Sums every payment across every order into one aggregate per method
  /// label, folding an order with no payments into the cash bucket for its
  /// full total.
  List<_MethodAggregate> _aggregate() {
    final counts = <String, int>{};
    final amounts = <String, double>{};
    for (final order in orders) {
      if (order.payments.isEmpty) {
        counts[_cashFallbackLabel] = (counts[_cashFallbackLabel] ?? 0) + 1;
        amounts[_cashFallbackLabel] = (amounts[_cashFallbackLabel] ?? 0) + order.total;
        continue;
      }
      for (final payment in order.payments) {
        final label = payment.label ?? _cashFallbackLabel;
        counts[label] = (counts[label] ?? 0) + 1;
        amounts[label] = (amounts[label] ?? 0) + payment.amount;
      }
    }
    return [
      for (final label in amounts.keys)
        _MethodAggregate(label: label, count: counts[label]!, amount: amounts[label]!),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final methods = _aggregate()..sort((a, b) => b.amount.compareTo(a.amount));
    final grandTotal = methods.fold(0.0, (s, m) => s + m.amount);

    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Payment analysis'))),
      body: orders.isEmpty || methods.isEmpty
          ? Center(child: Text(tr(context, 'No orders')))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tr(context, 'How customers paid'),
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                          const Divider(),
                          ListView.builder(
                            key: const Key('payment-analysis-list'),
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: methods.length,
                            itemBuilder: (context, i) => _methodRow(
                              context,
                              methods[i],
                              grandTotal: grandTotal,
                              isTop: i == 0,
                            ),
                          ),
                          const Divider(),
                          _grandTotalRow(context, grandTotal),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _methodRow(
    BuildContext context,
    _MethodAggregate method, {
    required double grandTotal,
    required bool isTop,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    // Guard against a zero grand total (every order netted to nothing) so the
    // bar fraction never divides by zero and renders as a blank instead of NaN.
    final share = grandTotal == 0 ? 0.0 : method.amount / grandTotal;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  method.label,
                  style: TextStyle(fontWeight: isTop ? FontWeight.bold : FontWeight.normal),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isTop) Icon(Icons.star, size: 16, color: colorScheme.primary),
              const SizedBox(width: 8),
              SizedBox(
                width: 40,
                child: Text('${method.count}', textAlign: TextAlign.right),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 80,
                child: Text(
                  formatAmount(method.amount),
                  textAlign: TextAlign.right,
                  style: TextStyle(fontWeight: isTop ? FontWeight.bold : FontWeight.normal),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 48,
                child: Text(
                  '${(share * 100).toStringAsFixed(1)}%',
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: share,
              minHeight: 6,
              backgroundColor: colorScheme.surfaceContainerHighest,
            ),
          ),
        ],
      ),
    );
  }

  Widget _grandTotalRow(BuildContext context, double grandTotal) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(tr(context, 'Grand total'), style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          Text(
            formatAmount(grandTotal),
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}
