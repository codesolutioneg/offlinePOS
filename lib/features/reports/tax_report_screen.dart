import 'package:flutter/material.dart';

import '../../domain/order.dart';

/// A tax report: net, tax and gross grouped by tax rate. Prices are tax-inclusive,
/// so the tax shown is the portion already contained in what customers paid.
class TaxReportScreen extends StatelessWidget {
  const TaxReportScreen({super.key, required this.orders, required this.formatAmount});

  final List<Order> orders;
  final String Function(double) formatAmount;

  @override
  Widget build(BuildContext context) {
    // rate% -> [gross, tax]
    final byRate = <double, List<double>>{};
    for (final o in orders) {
      final f = o.discountFactor;
      for (final l in o.lines) {
        if (l.taxRate <= 0) continue;
        final gross = l.total * f;
        final tax = gross - gross / (1 + l.taxRate / 100);
        final acc = byRate.putIfAbsent(l.taxRate, () => [0, 0]);
        acc[0] += gross;
        acc[1] += tax;
      }
    }
    final rates = byRate.keys.toList()..sort();
    final totalTax = byRate.values.fold(0.0, (s, v) => s + v[1]);
    final totalGross = byRate.values.fold(0.0, (s, v) => s + v[0]);

    return Scaffold(
      appBar: AppBar(title: const Text('Tax report')),
      body: rates.isEmpty
          ? const Center(child: Text('No tax recorded (prices carry no tax rate)'))
          : ListView(
              key: const Key('tax-list'),
              padding: const EdgeInsets.all(12),
              children: [
                const Row(children: [
                  Expanded(flex: 2, child: Text('Rate', style: TextStyle(fontWeight: FontWeight.bold))),
                  Expanded(flex: 3, child: Text('Net', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.bold))),
                  Expanded(flex: 3, child: Text('Tax', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.bold))),
                  Expanded(flex: 3, child: Text('Gross', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.bold))),
                ]),
                const Divider(),
                for (final r in rates)
                  Padding(
                    key: Key('tax-rate-${r.toStringAsFixed(0)}'),
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(children: [
                      Expanded(flex: 2, child: Text('${r.toStringAsFixed(r == r.roundToDouble() ? 0 : 1)}%')),
                      Expanded(flex: 3, child: Text(formatAmount(byRate[r]![0] - byRate[r]![1]), textAlign: TextAlign.right)),
                      Expanded(flex: 3, child: Text(formatAmount(byRate[r]![1]), textAlign: TextAlign.right)),
                      Expanded(flex: 3, child: Text(formatAmount(byRate[r]![0]), textAlign: TextAlign.right)),
                    ]),
                  ),
                const Divider(),
                Row(children: [
                  const Expanded(flex: 2, child: Text('Total', style: TextStyle(fontWeight: FontWeight.bold))),
                  Expanded(flex: 3, child: Text(formatAmount(totalGross - totalTax), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.bold))),
                  Expanded(flex: 3, child: Text(formatAmount(totalTax), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.bold))),
                  Expanded(flex: 3, child: Text(formatAmount(totalGross), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.bold))),
                ]),
              ],
            ),
    );
  }
}
