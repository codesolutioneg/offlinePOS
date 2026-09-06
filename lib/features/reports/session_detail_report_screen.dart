import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../domain/order.dart';
import 'report_export.dart';
import 'restaurant_analytics.dart';

/// A per-check ledger for the range/shift: one row per sale with its sub-total,
/// taxes (VAT plus service), total, tender(s), table, cashier, covers, check
/// discount, bill time and revenue centre. A split check lists each tender on its
/// own line, all summing to the check total. The footer totals reconcile with
/// every other report here.
class SessionDetailReportScreen extends StatelessWidget {
  const SessionDetailReportScreen({
    super.key,
    required this.orders,
    required this.formatAmount,
    this.cashLabel = 'Cash',
  });

  final List<Order> orders;
  final String Function(double) formatAmount;

  /// What an untendered (implicit cash) sale's tender is shown as.
  final String cashLabel;

  List<SessionCheck> get _checks => sessionChecks(orders, cashLabel: cashLabel);

  static String _time(DateTime d) {
    final l = d.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  ReportTable _table() {
    final checks = _checks;
    final rows = <List<String>>[
      for (final c in checks)
        [
          c.order.displayNo,
          _time(c.order.createdAt),
          c.order.type.label,
          c.order.tableLabel ?? '',
          c.order.cashierId,
          '${c.order.guestCount ?? 0}',
          c.subtotal.toStringAsFixed(2),
          c.checkDiscount.toStringAsFixed(2),
          c.taxes.toStringAsFixed(2),
          c.total.toStringAsFixed(2),
          [for (final t in c.tenders) '${t.label} ${t.amount.toStringAsFixed(2)}']
              .join(' + '),
        ],
    ];
    final subtotal = checks.fold(0.0, (s, c) => s + c.subtotal);
    final disc = checks.fold(0.0, (s, c) => s + c.checkDiscount);
    final taxes = checks.fold(0.0, (s, c) => s + c.taxes);
    final total = checks.fold(0.0, (s, c) => s + c.total);
    rows.add([
      'Total',
      '',
      '',
      '',
      '',
      '',
      subtotal.toStringAsFixed(2),
      disc.toStringAsFixed(2),
      taxes.toStringAsFixed(2),
      total.toStringAsFixed(2),
      '',
    ]);
    return ReportTable(
      header: const [
        'Order',
        'Bill time',
        'Revenue centre',
        'Table',
        'Cashier',
        'Covers',
        'Sub-Total',
        'Check discount',
        'Taxes',
        'Total',
        'Tenders',
      ],
      rows: rows,
    );
  }

  @override
  Widget build(BuildContext context) {
    final checks = _checks;
    final subtotal = checks.fold(0.0, (s, c) => s + c.subtotal);
    final disc = checks.fold(0.0, (s, c) => s + c.checkDiscount);
    final taxes = checks.fold(0.0, (s, c) => s + c.taxes);
    final total = checks.fold(0.0, (s, c) => s + c.total);
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Session detail')),
        actions: [
          reportExportAction(context,
              name: 'report-session-detail',
              title: tr(context, 'Session detail'),
              table: _table),
        ],
      ),
      body: checks.isEmpty
          ? Center(child: Text(tr(context, 'No orders')))
          : ListView(
              key: const Key('session-detail-list'),
              padding: const EdgeInsets.all(12),
              children: [
                for (final c in checks) _checkCard(context, c),
                _footer(context, subtotal, disc, taxes, total),
              ],
            ),
    );
  }

  Widget _checkCard(BuildContext context, SessionCheck c) {
    final small = Theme.of(context).textTheme.bodySmall;
    return Card(
      key: Key('check-${c.order.uuid}'),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text('#${c.order.displayNo}',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            Text(formatAmount(c.total),
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 2),
          Text(
              '${_time(c.order.createdAt)}  -  ${tr(context, c.order.type.label)}'
              '${c.order.tableLabel != null ? '  -  ${c.order.tableLabel}' : ''}',
              style: small),
          Text(
              '${tr(context, 'Cashier')}: ${c.order.cashierId}'
              '  -  ${tr(context, 'Covers')}: ${c.order.guestCount ?? 0}',
              style: small),
          const Divider(),
          _kv(context, tr(context, 'Sub-Total'), formatAmount(c.subtotal)),
          if (c.checkDiscount != 0)
            _kv(context, tr(context, 'Check discount'),
                formatAmount(c.checkDiscount)),
          _kv(context, tr(context, 'Taxes'), formatAmount(c.taxes)),
          _kv(context, tr(context, 'Total'), formatAmount(c.total), bold: true),
          const SizedBox(height: 4),
          for (final t in c.tenders)
            _kv(context, t.label, formatAmount(t.amount), dim: true),
        ]),
      ),
    );
  }

  Widget _footer(BuildContext context, double subtotal, double disc,
          double taxes, double total) =>
      Card(
        key: const Key('session-detail-footer'),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr(context, 'Totals'),
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const Divider(),
            _kv(context, tr(context, 'Sub-Total'), formatAmount(subtotal)),
            _kv(context, tr(context, 'Check discount'), formatAmount(disc)),
            _kv(context, tr(context, 'Taxes'), formatAmount(taxes)),
            _kv(context, tr(context, 'Total'), formatAmount(total), bold: true),
          ]),
        ),
      );

  Widget _kv(BuildContext context, String k, String v,
          {bool bold = false, bool dim = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(
              child: Text(k,
                  style: dim ? Theme.of(context).textTheme.bodySmall : null)),
          Text(v,
              style: dim
                  ? Theme.of(context).textTheme.bodySmall
                  : TextStyle(
                      fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
        ]),
      );
}
