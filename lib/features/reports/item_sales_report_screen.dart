import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../domain/catalogue.dart';
import '../../domain/order.dart';
import 'report_export.dart';
import 'restaurant_analytics.dart';

/// Sales per item, grouped under its category Group: units, net sales, cost of
/// goods, cost as a share of the item's sales, and the item's share of net. Group
/// totals and a grand total that reconciles with the group-sales report.
class ItemSalesReportScreen extends StatelessWidget {
  const ItemSalesReportScreen({
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

  List<ItemSalesRow> get _rows => itemSales(orders, categories, costs);

  static String _qty(double q) =>
      q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(2);

  ReportTable _table() {
    final rows = _rows;
    final grandNet = rows.fold(0.0, (s, r) => s + r.net);
    String share(double net) =>
        grandNet == 0 ? '0.0' : (net / grandNet * 100).toStringAsFixed(1);
    final out = <List<String>>[];
    var i = 0;
    while (i < rows.length) {
      final group = rows[i].group;
      var gQty = 0.0, gNet = 0.0, gCost = 0.0;
      while (i < rows.length && rows[i].group == group) {
        final r = rows[i];
        out.add([
          r.group,
          r.name,
          _qty(r.qty),
          r.net.toStringAsFixed(2),
          r.cost.toStringAsFixed(2),
          r.costPercent.toStringAsFixed(1),
          share(r.net),
        ]);
        gQty += r.qty;
        gNet += r.net;
        gCost += r.cost;
        i++;
      }
      out.add([
        group,
        'Group total',
        _qty(gQty),
        gNet.toStringAsFixed(2),
        gCost.toStringAsFixed(2),
        gNet == 0 ? '0.0' : (gCost / gNet * 100).toStringAsFixed(1),
        share(gNet),
      ]);
    }
    final grandCost = rows.fold(0.0, (s, r) => s + r.cost);
    out.add([
      'Grand total',
      '',
      _qty(rows.fold(0.0, (s, r) => s + r.qty)),
      grandNet.toStringAsFixed(2),
      grandCost.toStringAsFixed(2),
      grandNet == 0 ? '0.0' : (grandCost / grandNet * 100).toStringAsFixed(1),
      '100.0',
    ]);
    return ReportTable(
      header: const ['Group', 'Item', 'Qty', 'Sales', 'Cost', 'Cost %', 'Sale %'],
      rows: out,
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final grandNet = rows.fold(0.0, (s, r) => s + r.net);
    final grandCost = rows.fold(0.0, (s, r) => s + r.cost);
    final groups = <String>[];
    for (final r in rows) {
      if (groups.isEmpty || groups.last != r.group) groups.add(r.group);
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Item sales')),
        actions: [
          reportExportAction(context,
              name: 'report-item-sales',
              title: tr(context, 'Item sales'),
              table: _table),
        ],
      ),
      body: rows.isEmpty
          ? Center(child: Text(tr(context, 'No orders')))
          : ListView(
              key: const Key('item-sales-list'),
              padding: const EdgeInsets.all(12),
              children: [
                for (final group in groups)
                  _groupCard(context, group,
                      rows.where((r) => r.group == group).toList(), grandNet),
                _grandCard(context, grandNet, grandCost),
              ],
            ),
    );
  }

  Widget _groupCard(
      BuildContext context, String group, List<ItemSalesRow> items, double grandNet) {
    final gNet = items.fold(0.0, (s, r) => s + r.net);
    final gCost = items.fold(0.0, (s, r) => s + r.cost);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(group,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const Divider(),
          for (final r in items)
            _line(context, r.name, _qty(r.qty), formatAmount(r.net),
                formatAmount(r.cost), '${r.costPercent.toStringAsFixed(1)}%',
                grandNet == 0 ? 0 : r.net / grandNet),
          const Divider(),
          _line(context, tr(context, 'Group total'), '', formatAmount(gNet),
              formatAmount(gCost),
              '${(gNet == 0 ? 0 : gCost / gNet * 100).toStringAsFixed(1)}%',
              grandNet == 0 ? 0 : gNet / grandNet,
              bold: true),
        ]),
      ),
    );
  }

  Widget _line(BuildContext context, String name, String qty, String sales,
          String cost, String costPct, double share,
          {bool bold = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(
              flex: 5,
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
              flex: 3,
              child: Text(cost,
                  textAlign: TextAlign.right,
                  style: Theme.of(context).textTheme.bodySmall)),
          Expanded(
              flex: 2,
              child: Text(costPct,
                  textAlign: TextAlign.right,
                  style: Theme.of(context).textTheme.bodySmall)),
          Expanded(
              flex: 2,
              child: Text('${(share * 100).toStringAsFixed(1)}%',
                  textAlign: TextAlign.right,
                  style: Theme.of(context).textTheme.bodySmall)),
        ]),
      );

  Widget _grandCard(BuildContext context, double grandNet, double grandCost) => Card(
        key: const Key('item-sales-grand'),
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
                '${(grandNet == 0 ? 0 : grandCost / grandNet * 100).toStringAsFixed(1)}%'),
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
