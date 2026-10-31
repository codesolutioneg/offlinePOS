import 'package:flutter/material.dart';

import '../l10n.dart';
import '../orders.dart';
import '../theme.dart';
import '../widgets/owner_ui.dart';

class SalesSummaryScreen extends StatelessWidget {
  const SalesSummaryScreen({super.key, required this.orders});

  final List<OwnerOrder> orders;

  @override
  Widget build(BuildContext context) {
    final sales = salesForReports(orders);
    final refunds = [
      for (final o in withoutFullyCancelled(orders))
        if (o.isRefund || o.total < 0) o,
    ];
    final net = sales.fold(0.0, (s, o) => s + o.total);
    final disc = sales.fold(
        0.0, (s, o) => s + o.checkDiscount + o.lineDiscount);
    final byType = <String, double>{};
    final byPay = <String, double>{};
    for (final o in sales) {
      byType[o.orderType] = (byType[o.orderType] ?? 0) + o.total;
      if (o.payments.isEmpty) {
        byPay['Cash'] = (byPay['Cash'] ?? 0) + o.total;
      } else {
        for (final p in o.payments) {
          final label =
              (p.label ?? 'Cash').trim().isEmpty ? 'Cash' : p.label!.trim();
          byPay[label] = (byPay[label] ?? 0) + p.amount;
        }
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Sales summary'))),
      body: sales.isEmpty && refunds.isEmpty
          ? EmptyHint(tr(context, 'No data in this period'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
              children: [
                LayoutBuilder(builder: (context, box) {
                  final w = (box.maxWidth - 12) / 2;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      SizedBox(
                        width: w,
                        child: MetricTile(
                          label: tr(context, 'Orders'),
                          value: '${sales.length}',
                          icon: Icons.receipt_long_rounded,
                        ),
                      ),
                      SizedBox(
                        width: w,
                        child: MetricTile(
                          label: tr(context, 'Net sales'),
                          value: money(net),
                          icon: Icons.payments_rounded,
                          accent: AppColors.success,
                        ),
                      ),
                      SizedBox(
                        width: w,
                        child: MetricTile(
                          label: tr(context, 'Discount'),
                          value: money(disc),
                          icon: Icons.percent_rounded,
                          accent: const Color(0xFFEA580C),
                        ),
                      ),
                      SizedBox(
                        width: w,
                        child: MetricTile(
                          label: tr(context, 'Returns'),
                          value: money(refunds.fold(
                              0.0, (s, o) => s + o.total.abs())),
                          icon: Icons.undo_rounded,
                          accent: AppColors.danger,
                        ),
                      ),
                    ],
                  );
                }),
                const SizedBox(height: 18),
                OwnerCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SectionTitle(tr(context, 'Orders')),
                      const SizedBox(height: 8),
                      for (final e in byType.entries)
                        KvRow(e.key.isEmpty ? '—' : e.key, money(e.value)),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                OwnerCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SectionTitle(tr(context, 'Payments')),
                      const SizedBox(height: 8),
                      for (final e in (byPay.entries.toList()
                        ..sort((a, b) => b.value.compareTo(a.value))))
                        KvRow(e.key, money(e.value)),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
