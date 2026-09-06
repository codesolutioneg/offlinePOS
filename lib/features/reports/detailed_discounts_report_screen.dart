import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../domain/order.dart';
import 'report_export.dart';
import 'restaurant_analytics.dart';

/// One row per discounted line and per order-level (check) discount: when, which
/// order and table, the server, quantity, item, the raw price before the
/// discount, the price actually charged, the difference given away, and the
/// discount type. Totals close it.
class DetailedDiscountsReportScreen extends StatelessWidget {
  const DetailedDiscountsReportScreen({
    super.key,
    required this.orders,
    required this.formatAmount,
  });

  final List<Order> orders;
  final String Function(double) formatAmount;

  List<DiscountDetailRow> get _rows => discountDetails(orders);

  static String _qty(double q) =>
      q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(2);

  static String _time(DateTime d) {
    final l = d.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  static String _levelLabel(DiscountLevel l) =>
      l == DiscountLevel.check ? 'Check' : 'Line';

  ReportTable _table() {
    final rows = _rows;
    final diff = rows.fold(0.0, (s, r) => s + r.difference);
    return ReportTable(
      header: const [
        'Date',
        'Order',
        'Table',
        'Server',
        'Qty',
        'Item',
        'Raw price',
        'Charged price',
        'Difference',
        'Discount type',
      ],
      rows: [
        for (final r in rows)
          [
            _time(r.order.createdAt),
            r.order.displayNo,
            r.order.tableLabel ?? '',
            r.order.cashierId,
            _qty(r.qty),
            r.item,
            r.rawPrice.toStringAsFixed(2),
            r.chargedPrice.toStringAsFixed(2),
            r.difference.toStringAsFixed(2),
            '${_levelLabel(r.level)} - ${r.reason}',
          ],
        [
          'Total',
          '',
          '',
          '',
          '',
          '',
          '',
          '',
          diff.toStringAsFixed(2),
          '',
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final diff = rows.fold(0.0, (s, r) => s + r.difference);
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Detailed discounts')),
        actions: [
          if (rows.isNotEmpty)
            reportExportAction(context,
                name: 'report-detailed-discounts',
                title: tr(context, 'Detailed discounts'),
                table: _table),
        ],
      ),
      body: rows.isEmpty
          ? Center(
              child: Column(
                key: const Key('detailed-discounts-empty'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.percent,
                      size: 48, color: Theme.of(context).colorScheme.outline),
                  const SizedBox(height: 12),
                  Text(tr(context, 'No discounts given'),
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16)),
                ],
              ),
            )
          : ListView(
              key: const Key('detailed-discounts-list'),
              padding: const EdgeInsets.all(12),
              children: [
                for (final r in rows) _row(context, r),
                Card(
                  key: const Key('detailed-discounts-total'),
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(children: [
                      Expanded(
                        child: Text(tr(context, 'Total given away'),
                            style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      Text(formatAmount(diff),
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                    ]),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _row(BuildContext context, DiscountDetailRow r) {
    final small = Theme.of(context).textTheme.bodySmall;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text('${_qty(r.qty)} x ${r.item}',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            Text('- ${formatAmount(r.difference)}',
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.error)),
          ]),
          const SizedBox(height: 2),
          Text(
              '#${r.order.displayNo}  -  ${_time(r.order.createdAt)}'
              '${r.order.tableLabel != null ? '  -  ${r.order.tableLabel}' : ''}',
              style: small),
          Text('${tr(context, 'Server')}: ${r.order.cashierId}', style: small),
          Text(
              '${tr(context, _levelLabel(r.level))}  -  ${r.reason}  -  '
              '${formatAmount(r.rawPrice)} -> ${formatAmount(r.chargedPrice)}',
              style: small),
        ]),
      ),
    );
  }
}
