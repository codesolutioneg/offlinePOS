import 'package:flutter/material.dart';

import '../../core/db/attendance_store.dart';
import '../../core/i18n/l10n.dart';
import '../../domain/catalogue.dart';
import '../../domain/order.dart';
import 'report_export.dart';
import 'restaurant_analytics.dart';

/// The end-of-shift Z: one page that composes what the shift took and gave away.
///
/// Payment types, the tax split (service and VAT on their own lines), discounts,
/// refunds, sales by category Type, sales by revenue centre, food cost with its
/// margin, the averages and the labour hours on the clock. Every money figure is
/// built from the same helpers the other reports use, so this reconciles with all
/// of them.
///
/// What the till does not track is said so plainly rather than shown as a real
/// zero: dayparts, the money cost of labour, and an "Officer" channel are not
/// modelled here, and printing them as 0 would read as "we did none" rather than
/// "we do not measure this".
class SessionSummaryReportScreen extends StatelessWidget {
  const SessionSummaryReportScreen({
    super.key,
    required this.orders,
    required this.categories,
    required this.costs,
    required this.formatAmount,
    this.attendance = const [],
    this.rangeHours,
    this.cashLabel = 'Cash',
  });

  final List<Order> orders;
  final List<Category> categories;
  final Map<int, double> costs;
  final String Function(double) formatAmount;

  /// The clock-ins in the window, for labour hours. Empty simply reports no hours.
  final List<AttendanceEntry> attendance;

  /// The wall-clock hours the selected range spans, for sales per hour. Null on an
  /// unbounded range ("All"), where sales per hour has no meaning and is omitted.
  final double? rangeHours;

  /// What an untendered (implicit cash) sale's tender is shown as.
  final String cashLabel;

  ReportTotals get _totals => reportTotals(orders, costs);

  double get _labourHours {
    final now = DateTime.now();
    return attendance.fold(
        0.0, (s, e) => s + e.worked(now).inMinutes / 60.0);
  }

  ReportTable _table() {
    final t = _totals;
    final rows = <List<String>>[];
    void add(String section, String item, double value) =>
        rows.add([section, item, value.toStringAsFixed(2)]);

    for (final e in paymentTypes(orders, cashLabel: cashLabel).entries) {
      add('Payment types', e.key, e.value);
    }
    add('Tax types', 'Service', t.service);
    add('Tax types', 'VAT', t.vat);
    add('Discounts', 'Total given away', t.discount);
    add('Refunds', 'Total refunded', t.refunds);
    for (final e in netByType(orders, categories).entries) {
      add('Sales by type', e.key, e.value);
    }
    for (final r in revenueCentres(orders)) {
      add('Revenue centres', r.type.label, r.total);
    }
    add('Food cost', 'Net sales', t.net);
    add('Food cost', 'Cost of goods', t.cost);
    add('Food cost', 'Gross profit', t.grossProfit);
    rows.add(['Food cost', 'Cost %', t.costPercent.toStringAsFixed(1)]);
    rows.add(['Food cost', 'Margin %', t.marginPercent.toStringAsFixed(1)]);
    add('Averages', 'Average check', t.avgCheck);
    add('Averages', 'Average customer spend', t.avgCustomer);
    if (rangeHours != null && rangeHours! > 0) {
      add('Averages', 'Sales per hour', t.net / rangeHours!);
    }
    rows.add(['Labour', 'Hours worked', _labourHours.toStringAsFixed(2)]);
    return ReportTable(
      header: const ['Section', 'Item', 'Amount'],
      rows: rows,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = _totals;
    final payments = paymentTypes(orders, cashLabel: cashLabel);
    final byType = netByType(orders, categories);
    final centres = revenueCentres(orders);
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Session summary')),
        actions: [
          reportExportAction(context,
              name: 'report-session-summary',
              title: tr(context, 'Session summary'),
              table: _table),
        ],
      ),
      body: orders.isEmpty
          ? Center(child: Text(tr(context, 'No orders')))
          : ListView(
              key: const Key('session-summary-list'),
              padding: const EdgeInsets.all(12),
              children: [
                _section(context, tr(context, 'Payment types'), [
                  if (payments.isEmpty)
                    _kv(context, tr(context, 'No payments'), '')
                  else
                    for (final e in payments.entries)
                      _kv(context, e.key, formatAmount(e.value)),
                ]),
                _section(context, tr(context, 'Tax types'), [
                  _kv(context, tr(context, 'Service'), formatAmount(t.service)),
                  _kv(context, tr(context, 'VAT'), formatAmount(t.vat)),
                  _kv(context, tr(context, 'Taxes'), formatAmount(t.taxes),
                      bold: true),
                ]),
                _section(context, tr(context, 'Discounts'), [
                  _kv(context, tr(context, 'Total given away'),
                      formatAmount(t.discount)),
                ]),
                _section(context, tr(context, 'Refunds'), [
                  _kv(context, tr(context, 'Total refunded'),
                      formatAmount(t.refunds)),
                ]),
                _section(context, tr(context, 'Sales by type'), [
                  for (final e in byType.entries)
                    _kv(context, e.key, formatAmount(e.value)),
                  _kv(context, tr(context, 'Net sales'), formatAmount(t.net),
                      bold: true),
                ]),
                _section(context, tr(context, 'Revenue centers'), [
                  for (final r in centres)
                    _kv(context, tr(context, r.type.label),
                        formatAmount(r.total)),
                ]),
                _section(context, tr(context, 'Food cost'), [
                  _kv(context, tr(context, 'Net sales'), formatAmount(t.net)),
                  _kv(context, tr(context, 'Cost of goods'),
                      formatAmount(t.cost)),
                  _kv(context, tr(context, 'Gross profit'),
                      formatAmount(t.grossProfit),
                      bold: true),
                  _kv(context, tr(context, 'Cost %'),
                      '${t.costPercent.toStringAsFixed(1)}%'),
                  _kv(context, tr(context, 'Margin %'),
                      '${t.marginPercent.toStringAsFixed(1)}%'),
                ]),
                _section(context, tr(context, 'Averages'), [
                  _kv(context, tr(context, 'Average check'),
                      formatAmount(t.avgCheck)),
                  _kv(context, tr(context, 'Average customer spend'),
                      formatAmount(t.avgCustomer)),
                  if (rangeHours != null && rangeHours! > 0)
                    _kv(context, tr(context, 'Sales per hour'),
                        formatAmount(t.net / rangeHours!))
                  else
                    _notTracked(context, tr(context, 'Sales per hour')),
                ]),
                _section(context, tr(context, 'Labour'), [
                  _kv(context, tr(context, 'Hours worked'),
                      _labourHours.toStringAsFixed(2)),
                  _notTracked(context, tr(context, 'Labour cost')),
                ]),
                _section(context, tr(context, 'Not tracked'), [
                  _notTracked(context, tr(context, 'Dayparts')),
                  _notTracked(context, tr(context, 'Officer channel')),
                ]),
              ],
            ),
    );
  }

  Widget _section(BuildContext context, String title, List<Widget> children) =>
      Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const Divider(),
            ...children,
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

  Widget _notTracked(BuildContext context, String k) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(k)),
          Text(tr(context, 'Not tracked'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontStyle: FontStyle.italic,
                  color: Theme.of(context).colorScheme.outline)),
        ]),
      );
}
