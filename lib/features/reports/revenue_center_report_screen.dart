import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../domain/order.dart';
import 'report_export.dart';
import 'restaurant_analytics.dart';

/// Sales by revenue centre (order type): transactions, covers, net, taxes, total,
/// the average per transaction and the average per customer. A refund's money
/// reduces its centre but is not counted as a transaction or cover, so the
/// averages read against real sales. The totals row reconciles with the other
/// reports here.
class RevenueCenterReportScreen extends StatelessWidget {
  const RevenueCenterReportScreen({
    super.key,
    required this.orders,
    required this.formatAmount,
  });

  final List<Order> orders;
  final String Function(double) formatAmount;

  List<RevenueCentreRow> get _rows => revenueCentres(orders);

  ReportTable _table() {
    final rows = _rows;
    final trans = rows.fold(0, (s, r) => s + r.trans);
    final covers = rows.fold(0, (s, r) => s + r.covers);
    final net = rows.fold(0.0, (s, r) => s + r.net);
    final taxes = rows.fold(0.0, (s, r) => s + r.taxes);
    final total = rows.fold(0.0, (s, r) => s + r.total);
    return ReportTable(
      header: const [
        'Revenue centre',
        'Trans',
        'Cust',
        'Sales',
        'Taxes',
        'Total',
        'Trans Avg',
        'Customer Avg',
      ],
      rows: [
        for (final r in rows)
          [
            r.type.label,
            '${r.trans}',
            '${r.covers}',
            r.net.toStringAsFixed(2),
            r.taxes.toStringAsFixed(2),
            r.total.toStringAsFixed(2),
            r.transAvg.toStringAsFixed(2),
            r.customerAvg.toStringAsFixed(2),
          ],
        [
          'Total',
          '$trans',
          '$covers',
          net.toStringAsFixed(2),
          taxes.toStringAsFixed(2),
          total.toStringAsFixed(2),
          (trans == 0 ? 0 : total / trans).toStringAsFixed(2),
          (covers == 0 ? 0 : total / covers).toStringAsFixed(2),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final trans = rows.fold(0, (s, r) => s + r.trans);
    final covers = rows.fold(0, (s, r) => s + r.covers);
    final net = rows.fold(0.0, (s, r) => s + r.net);
    final taxes = rows.fold(0.0, (s, r) => s + r.taxes);
    final total = rows.fold(0.0, (s, r) => s + r.total);
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Sales by revenue center')),
        actions: [
          reportExportAction(context,
              name: 'report-revenue-center',
              title: tr(context, 'Sales by revenue center'),
              table: _table),
        ],
      ),
      body: rows.isEmpty
          ? Center(child: Text(tr(context, 'No orders')))
          : ListView(
              key: const Key('revenue-center-list'),
              padding: const EdgeInsets.all(12),
              children: [
                for (final r in rows) _centreCard(context, r),
                _footer(context, trans, covers, net, taxes, total),
              ],
            ),
    );
  }

  Widget _centreCard(BuildContext context, RevenueCentreRow r) => Card(
        key: Key('centre-${r.type.name}'),
        margin: const EdgeInsets.only(bottom: 8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(tr(context, r.type.label),
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16)),
              ),
              Text(formatAmount(r.total),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ]),
            const Divider(),
            _kv(context, tr(context, 'Transactions'), '${r.trans}'),
            _kv(context, tr(context, 'Customers'), '${r.covers}'),
            _kv(context, tr(context, 'Sales'), formatAmount(r.net)),
            _kv(context, tr(context, 'Taxes'), formatAmount(r.taxes)),
            _kv(context, tr(context, 'Transaction average'),
                formatAmount(r.transAvg)),
            _kv(context, tr(context, 'Customer average'),
                formatAmount(r.customerAvg)),
          ]),
        ),
      );

  Widget _footer(BuildContext context, int trans, int covers, double net,
          double taxes, double total) =>
      Card(
        key: const Key('revenue-center-footer'),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr(context, 'Totals'),
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const Divider(),
            _kv(context, tr(context, 'Transactions'), '$trans'),
            _kv(context, tr(context, 'Customers'), '$covers'),
            _kv(context, tr(context, 'Sales'), formatAmount(net)),
            _kv(context, tr(context, 'Taxes'), formatAmount(taxes)),
            _kv(context, tr(context, 'Total'), formatAmount(total), bold: true),
          ]),
        ),
      );

  Widget _kv(BuildContext context, String k, String v, {bool bold = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(k)),
          Text(v,
              style:
                  TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
        ]),
      );
}
