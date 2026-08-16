import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../domain/order.dart';
import 'report_export.dart';

/// A tax report: net, tax and gross grouped by tax rate. Prices are tax-inclusive,
/// so the tax shown is the portion already contained in what customers paid.
class TaxReportScreen extends StatelessWidget {
  const TaxReportScreen({super.key, required this.orders, required this.formatAmount});

  final List<Order> orders;
  final String Function(double) formatAmount;

  /// Gross and tax per rate, keyed by the rate itself. One pass, shared by the
  /// screen and the download so the exported file cannot drift from the page.
  Map<double, List<double>> _byRate() {
    final byRate = <double, List<double>>{};
    for (final o in orders) {
      // The service charge travels inside the line prices, so the server taxes it at
      // each item's own rate. The report has to include it or it understates the tax
      // that was actually booked.
      final f = o.discountFactor * o.serviceChargeFactor;
      for (final l in o.lines) {
        if (l.taxRate <= 0) continue;
        final gross = l.total * f;
        final tax = gross - gross / (1 + l.taxRate / 100);
        final acc = byRate.putIfAbsent(l.taxRate, () => [0, 0]);
        acc[0] += gross;
        acc[1] += tax;
      }
    }
    return byRate;
  }

  static String _rate(double r) =>
      '${r.toStringAsFixed(r == r.roundToDouble() ? 0 : 1)}%';

  ReportTable _table() {
    final byRate = _byRate();
    final rates = byRate.keys.toList()..sort();
    return ReportTable(
      header: const ['Rate', 'Net', 'Tax', 'Gross'],
      rows: [
        for (final r in rates)
          [
            _rate(r),
            (byRate[r]![0] - byRate[r]![1]).toStringAsFixed(2),
            byRate[r]![1].toStringAsFixed(2),
            byRate[r]![0].toStringAsFixed(2),
          ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final byRate = _byRate();
    final rates = byRate.keys.toList()..sort();
    final totalTax = byRate.values.fold(0.0, (s, v) => s + v[1]);
    final totalGross = byRate.values.fold(0.0, (s, v) => s + v[0]);

    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Tax report')),
        actions: [
          reportExportAction(context,
              name: 'report-tax', title: tr(context, 'Tax'), table: _table),
        ],
      ),
      body: rates.isEmpty
          ? Center(child: Text(tr(context, 'No tax recorded (prices carry no tax rate)')))
          : ListView(
              key: const Key('tax-list'),
              padding: const EdgeInsets.all(12),
              children: [
                Row(children: [
                  Expanded(flex: 2, child: Text(tr(context, 'Rate'), style: const TextStyle(fontWeight: FontWeight.bold))),
                  Expanded(flex: 3, child: Text(tr(context, 'Net'), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.bold))),
                  Expanded(flex: 3, child: Text(tr(context, 'Tax'), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.bold))),
                  Expanded(flex: 3, child: Text(tr(context, 'Gross'), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.bold))),
                ]),
                const Divider(),
                for (final r in rates)
                  Padding(
                    key: Key('tax-rate-${r.toStringAsFixed(0)}'),
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(children: [
                      Expanded(flex: 2, child: Text(_rate(r))),
                      Expanded(flex: 3, child: Text(formatAmount(byRate[r]![0] - byRate[r]![1]), textAlign: TextAlign.right)),
                      Expanded(flex: 3, child: Text(formatAmount(byRate[r]![1]), textAlign: TextAlign.right)),
                      Expanded(flex: 3, child: Text(formatAmount(byRate[r]![0]), textAlign: TextAlign.right)),
                    ]),
                  ),
                const Divider(),
                Row(children: [
                  Expanded(flex: 2, child: Text(tr(context, 'Total'), style: const TextStyle(fontWeight: FontWeight.bold))),
                  Expanded(flex: 3, child: Text(formatAmount(totalGross - totalTax), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.bold))),
                  Expanded(flex: 3, child: Text(formatAmount(totalTax), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.bold))),
                  Expanded(flex: 3, child: Text(formatAmount(totalGross), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.bold))),
                ]),
              ],
            ),
    );
  }
}
