import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../domain/order.dart';
import 'report_export.dart';
import 'restaurant_analytics.dart';

/// Sales across several business days: one row per day, split by channel (Table
/// Service, Delivery, Take Away) with each channel's sales, checks and average
/// check, plus the day's customers, net sales and total including tax and
/// service. A totals row and an averages row close it. The channel sums add to
/// the day's net; the day nets add to the grand net that reconciles elsewhere.
class DailySalesReportScreen extends StatelessWidget {
  const DailySalesReportScreen({
    super.key,
    required this.orders,
    required this.formatAmount,
  });

  final List<Order> orders;
  final String Function(double) formatAmount;

  List<DailySalesRow> get _rows => dailySales(orders);

  static const _channels = [
    SalesChannel.tableService,
    SalesChannel.delivery,
    SalesChannel.takeAway,
  ];

  ReportTable _table() {
    final rows = _rows;
    final header = <String>['Day'];
    for (final c in _channels) {
      header.addAll(['${c.label} sales', '${c.label} checks', '${c.label} avg']);
    }
    header.addAll(['Customers', 'Total Sales', 'Total incl tax']);
    List<String> line(String day, double Function(SalesChannel) net,
        int Function(SalesChannel) checks, double Function(SalesChannel) avg,
        int customers, double totalNet, double totalIncl) {
      final r = <String>[day];
      for (final c in _channels) {
        r.addAll([
          net(c).toStringAsFixed(2),
          '${checks(c)}',
          avg(c).toStringAsFixed(2),
        ]);
      }
      r.addAll([
        '$customers',
        totalNet.toStringAsFixed(2),
        totalIncl.toStringAsFixed(2),
      ]);
      return r;
    }

    final out = <List<String>>[
      for (final d in rows)
        line(d.day, d.channelNet, d.channelChecks, d.channelAvg, d.customers,
            d.net, d.totalInclTax),
    ];
    // Totals and averages across every day.
    double chanNet(SalesChannel c) => rows.fold(0.0, (s, d) => s + d.channelNet(c));
    int chanChecks(SalesChannel c) => rows.fold(0, (s, d) => s + d.channelChecks(c));
    final custs = rows.fold(0, (s, d) => s + d.customers);
    final net = rows.fold(0.0, (s, d) => s + d.net);
    final incl = rows.fold(0.0, (s, d) => s + d.totalInclTax);
    out.add(line('Total', chanNet, chanChecks,
        (c) => chanChecks(c) == 0 ? 0 : chanNet(c) / chanChecks(c), custs, net,
        incl));
    final n = rows.isEmpty ? 1 : rows.length;
    out.add(line('AVG', (c) => chanNet(c) / n, (c) => (chanChecks(c) / n).round(),
        (c) => chanChecks(c) == 0 ? 0 : chanNet(c) / chanChecks(c),
        (custs / n).round(), net / n, incl / n));
    return ReportTable(header: header, rows: out);
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final net = rows.fold(0.0, (s, d) => s + d.net);
    final incl = rows.fold(0.0, (s, d) => s + d.totalInclTax);
    final custs = rows.fold(0, (s, d) => s + d.customers);
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Daily sales')),
        actions: [
          reportExportAction(context,
              name: 'report-daily-sales',
              title: tr(context, 'Daily sales'),
              table: _table),
        ],
      ),
      body: rows.isEmpty
          ? Center(child: Text(tr(context, 'No orders')))
          : ListView(
              key: const Key('daily-sales-list'),
              padding: const EdgeInsets.all(12),
              children: [
                for (final d in rows) _dayCard(context, d),
                _footer(context, net, incl, custs, rows.length),
              ],
            ),
    );
  }

  Widget _dayCard(BuildContext context, DailySalesRow d) => Card(
        key: Key('day-${d.day}'),
        margin: const EdgeInsets.only(bottom: 8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(d.day,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16)),
              ),
              Text(formatAmount(d.totalInclTax),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ]),
            const Divider(),
            for (final c in _channels)
              _kv(
                  context,
                  tr(context, c.label),
                  '${formatAmount(d.channelNet(c))}  '
                      '(${d.channelChecks(c)} ${tr(context, 'checks')}, '
                      '${tr(context, 'avg')} ${formatAmount(d.channelAvg(c))})'),
            const Divider(),
            _kv(context, tr(context, 'Customers'), '${d.customers}'),
            _kv(context, tr(context, 'Total sales'), formatAmount(d.net)),
            _kv(context, tr(context, 'Total incl tax'),
                formatAmount(d.totalInclTax),
                bold: true),
          ]),
        ),
      );

  Widget _footer(BuildContext context, double net, double incl, int custs,
          int days) =>
      Card(
        key: const Key('daily-sales-footer'),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr(context, 'Totals'),
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const Divider(),
            _kv(context, tr(context, 'Days'), '$days'),
            _kv(context, tr(context, 'Customers'), '$custs'),
            _kv(context, tr(context, 'Total sales'), formatAmount(net)),
            _kv(context, tr(context, 'Total incl tax'), formatAmount(incl),
                bold: true),
            if (days > 0)
              _kv(context, tr(context, 'Average per day'),
                  formatAmount(incl / days)),
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
