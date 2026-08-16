import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../core/widgets/feedback.dart';
import '../../domain/order.dart';
import 'report_export.dart';

/// One row in the cashier table: a cashier's order count and revenue
/// aggregated across every order passed to the screen.
class _CashierAggregate {
  _CashierAggregate(this.cashierId);
  final String cashierId;
  int orderCount = 0;
  double total = 0;

  double get average => orderCount == 0 ? 0 : total / orderCount;
}

/// A read-only cashier-performance report, computed entirely from the orders
/// already on the till. It never touches the database or the network itself:
/// the caller decides what "today" or "this shift" means and hands in the
/// finished order list, so the report stays a pure view.
class CashierReportScreen extends StatelessWidget {
  const CashierReportScreen({
    super.key,
    required this.orders,
    required this.formatAmount,
  });

  final List<Order> orders;
  final String Function(double) formatAmount;

  /// Groups every order by cashierId, then sorts by total sales descending so
  /// the top performer is on top, which is the whole point of the report.
  List<_CashierAggregate> _byCashier() {
    final byId = <String, _CashierAggregate>{};
    for (final o in orders) {
      final agg = byId.putIfAbsent(
          o.cashierId, () => _CashierAggregate(o.cashierId));
      agg.orderCount += 1;
      agg.total += o.total;
    }
    final list = byId.values.toList()
      ..sort((a, b) => b.total.compareTo(a.total));
    return list;
  }

  ReportTable _table() => ReportTable(
        header: const ['Cashier', 'Orders', 'Total', 'Average'],
        rows: [
          for (final c in _byCashier())
            [
              c.cashierId,
              '${c.orderCount}',
              c.total.toStringAsFixed(2),
              c.average.toStringAsFixed(2),
            ],
        ],
      );

  Widget _headerCell(String text) => Expanded(
        child: Text(
          text,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      );

  Widget _cell(String text, {bool bold = false}) => Expanded(
        child: Text(
          text,
          style: TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final cashiers = _byCashier();
    final totalOrders = orders.length;
    final totalSales = orders.fold(0.0, (s, o) => s + o.total);
    final overallAverage = totalOrders == 0 ? 0.0 : totalSales / totalOrders;

    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Cashier performance')),
        actions: [
          reportExportAction(context,
              name: 'report-cashier',
              title: tr(context, 'Cashier performance'),
              table: _table),
        ],
      ),
      body: cashiers.isEmpty
          ? EmptyState(
              icon: Icons.bar_chart_outlined,
              title: tr(context, 'No orders'),
              message: tr(context, 'Cashier totals will show up once orders come in'),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        _headerCell(tr(context, 'Cashier')),
                        _headerCell(tr(context, 'Orders')),
                        _headerCell(tr(context, 'Total sales')),
                        _headerCell(tr(context, 'Avg order')),
                      ]),
                      const Divider(),
                      // Bounded height list nested inside the outer scroll view, so
                      // a long roster doesn't need its own separate scroll gesture.
                      ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: cashiers.length * 48.0),
                        child: ListView.builder(
                          key: const Key('cashier-report-list'),
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: cashiers.length,
                          itemBuilder: (context, i) {
                            final c = cashiers[i];
                            return Padding(
                              key: Key('cashier-row-${c.cashierId}'),
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Row(children: [
                                _cell(c.cashierId),
                                _cell('${c.orderCount}'),
                                _cell(formatAmount(c.total)),
                                _cell(formatAmount(c.average)),
                              ]),
                            );
                          },
                        ),
                      ),
                      const Divider(),
                      Row(
                        key: const Key('cashier-report-overall-row'),
                        children: [
                          _cell(tr(context, 'Overall'), bold: true),
                          _cell('$totalOrders', bold: true),
                          _cell(formatAmount(totalSales), bold: true),
                          _cell(formatAmount(overallAverage), bold: true),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}
