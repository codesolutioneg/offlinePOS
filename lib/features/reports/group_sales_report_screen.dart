import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../domain/catalogue.dart';
import '../../domain/order.dart';
import 'report_export.dart';
import 'restaurant_analytics.dart';

/// Sales rolled up by category Type (the super-type above each category) and then
/// by Group (the category itself): units, net sales, each group's share of net,
/// its cost of goods and its cost as a share of its own sales. A subtotal per
/// Type and a grand total that reconciles with every other report here.
///
/// A pure view over the orders, categories and costs handed in.
class GroupSalesReportScreen extends StatelessWidget {
  const GroupSalesReportScreen({
    super.key,
    required this.orders,
    required this.categories,
    required this.costs,
    required this.formatAmount,
  });

  final List<Order> orders;
  final List<Category> categories;
  final Map<int, double> costs;
  final String Function(double) formatAmount;

  List<GroupSalesRow> get _rows => groupSales(orders, categories, costs);

  static String _qty(double q) =>
      q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(2);

  static String _pct(double p) => '${p.toStringAsFixed(1)}%';

  ReportTable _table() {
    final rows = _rows;
    final grandNet = rows.fold(0.0, (s, r) => s + r.net);
    String share(double net) =>
        grandNet == 0 ? '0.0' : (net / grandNet * 100).toStringAsFixed(1);
    final out = <List<String>>[];
    var i = 0;
    while (i < rows.length) {
      final type = rows[i].type;
      var typeQty = 0.0, typeNet = 0.0, typeCost = 0.0;
      while (i < rows.length && rows[i].type == type) {
        final r = rows[i];
        out.add([
          r.type,
          r.group,
          _qty(r.qty),
          r.net.toStringAsFixed(2),
          share(r.net),
          r.cost.toStringAsFixed(2),
          r.costPercent.toStringAsFixed(1),
        ]);
        typeQty += r.qty;
        typeNet += r.net;
        typeCost += r.cost;
        i++;
      }
      out.add([
        type,
        'Subtotal',
        _qty(typeQty),
        typeNet.toStringAsFixed(2),
        share(typeNet),
        typeCost.toStringAsFixed(2),
        typeNet == 0 ? '0.0' : (typeCost / typeNet * 100).toStringAsFixed(1),
      ]);
    }
    final grandCost = rows.fold(0.0, (s, r) => s + r.cost);
    out.add([
      'Grand total',
      '',
      _qty(rows.fold(0.0, (s, r) => s + r.qty)),
      grandNet.toStringAsFixed(2),
      '100.0',
      grandCost.toStringAsFixed(2),
      grandNet == 0 ? '0.0' : (grandCost / grandNet * 100).toStringAsFixed(1),
    ]);
    return ReportTable(
      header: const ['Type', 'Group', 'Qty', 'Sales', 'Sale %', 'Cost', 'Cost %'],
      rows: out,
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final grandNet = rows.fold(0.0, (s, r) => s + r.net);
    final grandCost = rows.fold(0.0, (s, r) => s + r.cost);
    // Preserve the grouped order while splitting into per-Type sections.
    final types = <String>[];
    for (final r in rows) {
      if (types.isEmpty || types.last != r.type) types.add(r.type);
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Group sales')),
        actions: [
          reportExportAction(context,
              name: 'report-group-sales',
              title: tr(context, 'Group sales'),
              table: _table),
        ],
      ),
      body: rows.isEmpty
          ? Center(child: Text(tr(context, 'No orders')))
          : ListView(
              key: const Key('group-sales-list'),
              padding: const EdgeInsets.all(12),
              children: [
                for (final type in types)
                  _typeCard(context, type,
                      rows.where((r) => r.type == type).toList(), grandNet),
                _grandCard(context, grandNet, grandCost),
              ],
            ),
    );
  }

  Widget _typeCard(
      BuildContext context, String type, List<GroupSalesRow> groups, double grandNet) {
    final typeNet = groups.fold(0.0, (s, r) => s + r.net);
    final typeCost = groups.fold(0.0, (s, r) => s + r.cost);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(type,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const Divider(),
          for (final r in groups)
            _line(context, r.group, _qty(r.qty), formatAmount(r.net),
                grandNet == 0 ? 0 : r.net / grandNet, formatAmount(r.cost),
                _pct(r.costPercent)),
          const Divider(),
          _line(context, tr(context, 'Subtotal'), '', formatAmount(typeNet),
              grandNet == 0 ? 0 : typeNet / grandNet, formatAmount(typeCost),
              _pct(typeNet == 0 ? 0 : typeCost / typeNet * 100),
              bold: true),
        ]),
      ),
    );
  }

  Widget _line(BuildContext context, String name, String qty, String sales,
          double share, String cost, String costPct,
          {bool bold = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(
              flex: 4,
              child: Text(name,
                  style: TextStyle(
                      fontWeight: bold ? FontWeight.bold : FontWeight.normal))),
          if (qty.isNotEmpty)
            Expanded(
                flex: 2,
                child: Text(qty,
                    textAlign: TextAlign.right,
                    style: Theme.of(context).textTheme.bodySmall))
          else
            const Spacer(flex: 2),
          Expanded(
              flex: 3,
              child: Text(sales,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                      fontWeight: bold ? FontWeight.bold : FontWeight.normal))),
          Expanded(
              flex: 2,
              child: Text('${(share * 100).toStringAsFixed(1)}%',
                  textAlign: TextAlign.right,
                  style: Theme.of(context).textTheme.bodySmall)),
          Expanded(
              flex: 3,
              child: Text(cost,
                  textAlign: TextAlign.right,
                  style: Theme.of(context).textTheme.bodySmall)),
          Expanded(
              flex: 2,
              child: Text(costPct,
                  textAlign: TextAlign.right,
                  style: Theme.of(context).textTheme.bodySmall)),
        ]),
      );

  Widget _grandCard(BuildContext context, double grandNet, double grandCost) => Card(
        key: const Key('group-sales-grand'),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr(context, 'Grand total'),
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const Divider(),
            _kv(tr(context, 'Sales'), formatAmount(grandNet), bold: true),
            _kv(tr(context, 'Cost'), formatAmount(grandCost)),
            _kv(tr(context, 'Cost %'),
                _pct(grandNet == 0 ? 0 : grandCost / grandNet * 100)),
          ]),
        ),
      );

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
