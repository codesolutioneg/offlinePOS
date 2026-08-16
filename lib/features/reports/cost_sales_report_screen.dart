import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../core/widgets/feedback.dart';
import '../../domain/order.dart';
import 'product_margins.dart';
import 'report_export.dart';

/// What the food cost against what it sold for.
///
/// The till has always been able to say what came in; with the cost down from the
/// catalogue it can say what was left, which is the number a shop actually runs on.
/// A product the server never costed is listed apart and left out of the totals, so
/// nothing is ever counted as free.
class CostSalesReportScreen extends StatelessWidget {
  const CostSalesReportScreen({
    super.key,
    required this.orders,
    required this.costs,
    required this.formatAmount,
  });

  final List<Order> orders;

  /// Product id to unit cost, as the last catalogue refresh stated it. A product
  /// absent from here has no known cost.
  final Map<int, double> costs;
  final String Function(double) formatAmount;

  List<ProductMargin> get _rows => productMargins(orders, costs);

  ReportTable _table(List<ProductMargin> rows) => ReportTable(
        header: const ['Product', 'Units', 'Revenue', 'Cost', 'Margin', 'Margin %'],
        rows: [
          for (final r in rows)
            [
              r.name,
              _qty(r.units),
              r.revenue.toStringAsFixed(2),
              r.costed ? r.cost.toStringAsFixed(2) : '',
              r.costed ? r.margin.toStringAsFixed(2) : '',
              r.costed ? r.marginPercent.toStringAsFixed(1) : '',
            ],
        ],
      );

  static String _qty(double q) =>
      q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final costed = rows.where((r) => r.costed).toList();
    final uncosted = rows.where((r) => !r.costed).toList();
    final revenue = costed.fold(0.0, (s, r) => s + r.revenue);
    final cost = costed.fold(0.0, (s, r) => s + r.cost);
    final margin = revenue - cost;

    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Cost vs sales')),
        actions: [
          reportExportAction(context,
              name: 'report-cost-vs-sales', title: tr(context, 'Cost vs sales'), table: () => _table(rows)),
        ],
      ),
      body: costed.isEmpty
          ? Center(
              child: EmptyState(
                key: const Key('cost-empty-state'),
                icon: Icons.savings_outlined,
                title: tr(context, 'No costs yet'),
                message: tr(context,
                    'Costs come down with the menu. Set a cost on the products in Odoo and sync.'),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _card(context, tr(context, 'Overview'), [
                  _row(tr(context, 'Revenue'), formatAmount(revenue)),
                  _row(tr(context, 'Cost'), formatAmount(cost)),
                  _row(tr(context, 'Margin'), formatAmount(margin), bold: true),
                  _row(
                      tr(context, 'Margin %'),
                      revenue == 0
                          ? '-'
                          : '${(margin / revenue * 100).toStringAsFixed(1)}%'),
                  _row(tr(context, 'Costed items'), '${costed.length}'),
                  if (uncosted.isNotEmpty)
                    _row(tr(context, 'Not costed'), '${uncosted.length}'),
                ]),
                _card(context, tr(context, 'By product'), [
                  Column(
                    key: const Key('cost-by-product'),
                    children: [for (final r in costed) _productRow(context, r)],
                  ),
                ]),
                if (uncosted.isNotEmpty)
                  _card(context, tr(context, 'Not costed'), [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                          tr(context,
                              'Products with no cost are left out of the totals, so nothing is counted as free.'),
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                    Column(
                      key: const Key('cost-not-costed'),
                      children: [
                        for (final r in uncosted)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(r.name),
                            subtitle: Text('${_qty(r.units)} ${tr(context, 'Units')}'),
                            trailing: Text(formatAmount(r.revenue)),
                          ),
                      ],
                    ),
                  ]),
              ],
            ),
    );
  }

  Widget _productRow(BuildContext context, ProductMargin r) => ListTile(
        key: Key('cost-product-${r.productId}'),
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(r.name),
        subtitle: Text('${_qty(r.units)} x  ${formatAmount(r.revenue)} '
            '-  ${formatAmount(r.cost)}'),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(formatAmount(r.margin),
                style: const TextStyle(fontWeight: FontWeight.bold)),
            Text('${r.marginPercent.toStringAsFixed(1)}%',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      );

  Widget _row(String k, String v, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(child: Text(k)),
          Text(v,
              style: TextStyle(
                  fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
        ]),
      );

  Widget _card(BuildContext context, String title, List<Widget> children) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const Divider(),
            ...children,
          ]),
        ),
      );
}
