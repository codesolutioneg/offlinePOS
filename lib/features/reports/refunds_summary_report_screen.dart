import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../domain/order.dart';
import 'report_export.dart';
import 'restaurant_analytics.dart';

/// A refunds summary for the range: how many refunds and the money handed back,
/// net, tax and total. Shows zeros rather than an empty page when nothing was
/// refunded, so a manager can tell "none" from "not run".
class RefundsSummaryReportScreen extends StatelessWidget {
  const RefundsSummaryReportScreen({
    super.key,
    required this.orders,
    required this.formatAmount,
  });

  final List<Order> orders;
  final String Function(double) formatAmount;

  RefundSummary get _summary => refundSummary(orders);

  ReportTable _table() {
    final s = _summary;
    return ReportTable(
      header: const ['Item', 'Value'],
      rows: [
        ['Refunds', '${s.count}'],
        ['Net refunded', s.net.toStringAsFixed(2)],
        ['Tax refunded', s.taxes.toStringAsFixed(2)],
        ['Total refunded', s.total.toStringAsFixed(2)],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _summary;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Refunds summary')),
        actions: [
          reportExportAction(context,
              name: 'report-refunds-summary',
              title: tr(context, 'Refunds summary'),
              table: _table),
        ],
      ),
      body: ListView(
        key: const Key('refunds-summary-list'),
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child:
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr(context, 'Refunds summary'),
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16)),
                const Divider(),
                _kv(tr(context, 'Refunds'), '${s.count}'),
                _kv(tr(context, 'Net refunded'), formatAmount(s.net)),
                _kv(tr(context, 'Tax refunded'), formatAmount(s.taxes)),
                _kv(tr(context, 'Total refunded'), formatAmount(s.total),
                    bold: true),
              ]),
            ),
          ),
          if (s.count == 0)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(tr(context, 'No refunds in this range.'),
                  key: const Key('refunds-summary-none'),
                  textAlign: TextAlign.center),
            ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(child: Text(k)),
          Text(v,
              style:
                  TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
        ]),
      );
}
