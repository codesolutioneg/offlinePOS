import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../core/widgets/feedback.dart';
import '../../domain/order.dart';
import 'report_export.dart';

/// One modifier over the period: how much of it went out and what it earned.
class _ModifierAggregate {
  _ModifierAggregate({required this.id, required this.name});
  final int id;
  final String name;

  /// Modifier units sold, which is the line quantity times the modifier's own
  /// quantity: two burgers with extra cheese are two cheeses.
  double quantity = 0;
  double revenue = 0;

  /// How many lines carried it, so a cheap add-on on every plate still stands out.
  int lines = 0;
}

/// What the add-ons are doing: which modifiers sell, and what they are worth.
///
/// Free modifiers ("no onions") earn nothing but still tell the kitchen what the
/// shop is really serving, so they are listed with a zero value rather than
/// dropped. A pure view over the orders handed in.
class ModifierReportScreen extends StatelessWidget {
  const ModifierReportScreen({
    super.key,
    required this.orders,
    required this.formatAmount,
  });

  final List<Order> orders;
  final String Function(double) formatAmount;

  /// Grouped by modifier id, falling back to the name for a modifier that has no
  /// id of its own, so two differently named add-ons never merge into one row.
  List<_ModifierAggregate> _aggregate() {
    final byKey = <String, _ModifierAggregate>{};
    for (final o in orders) {
      for (final l in o.lines) {
        for (final m in l.modifiers) {
          final key = m.modifierId == 0 ? 'n:${m.name}' : 'i:${m.modifierId}';
          final agg = byKey.putIfAbsent(
              key, () => _ModifierAggregate(id: m.modifierId, name: m.name));
          agg.quantity += m.quantity * l.quantity;
          agg.revenue += m.total * l.quantity;
          agg.lines += 1;
        }
      }
    }
    return byKey.values.toList()
      ..sort((a, b) {
        final byMoney = b.revenue.compareTo(a.revenue);
        if (byMoney != 0) return byMoney;
        final byQty = b.quantity.compareTo(a.quantity);
        return byQty != 0 ? byQty : a.name.compareTo(b.name);
      });
  }

  static String _qty(double q) =>
      q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(2);

  ReportTable _table(List<_ModifierAggregate> rows) => ReportTable(
        header: const ['Modifier', 'Id', 'Lines', 'Quantity', 'Revenue'],
        rows: [
          for (final m in rows)
            [
              m.name,
              '${m.id}',
              '${m.lines}',
              _qty(m.quantity),
              m.revenue.toStringAsFixed(2),
            ],
        ],
      );

  @override
  Widget build(BuildContext context) {
    final rows = _aggregate();
    final revenue = rows.fold(0.0, (s, m) => s + m.revenue);

    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Modifiers')),
        actions: [
          reportExportAction(context,
              name: 'report-modifiers', title: tr(context, 'Modifiers'), table: () => _table(rows)),
        ],
      ),
      body: rows.isEmpty
          ? Center(
              child: EmptyState(
                key: const Key('modifiers-empty-state'),
                icon: Icons.tune,
                title: tr(context, 'No modifiers'),
                message: tr(context, 'Nothing was sold with an add-on in this range.'),
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tr(context, 'Modifiers'),
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 16)),
                      Text(
                          '${rows.length} · ${formatAmount(revenue)}',
                          key: const Key('modifier-total'),
                          style: Theme.of(context).textTheme.bodySmall),
                      const Divider(),
                      Column(
                        key: const Key('modifier-list'),
                        children: [
                          for (final m in rows)
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(m.name),
                              subtitle: Text(
                                  '${_qty(m.quantity)} · ${m.lines} ${tr(context, m.lines == 1 ? 'line' : 'lines')}'),
                              trailing: Text(formatAmount(m.revenue)),
                            ),
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
