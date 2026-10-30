import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../l10n.dart';
import '../orders.dart';
import '../theme.dart';
import '../widgets/owner_ui.dart';

class CostsScreen extends StatelessWidget {
  const CostsScreen({
    super.key,
    required this.orders,
    required this.costs,
    this.embedded = false,
  });

  final List<OwnerOrder> orders;
  final Map<int, double> costs;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final sales = salesForReports(orders);
    final byItem = <String, ({double qty, double net, double cost})>{};
    for (final o in sales) {
      for (final l in o.lines) {
        final was = byItem[l.name];
        final c = (costs[l.productId] ?? 0) * l.quantity;
        byItem[l.name] = (
          qty: (was?.qty ?? 0) + l.quantity,
          net: (was?.net ?? 0) + l.total,
          cost: (was?.cost ?? 0) + c,
        );
      }
    }
    final rows = byItem.entries.toList()
      ..sort((a, b) => b.value.net.compareTo(a.value.net));
    final net = rows.fold(0.0, (s, e) => s + e.value.net);
    final cost = rows.fold(0.0, (s, e) => s + e.value.cost);
    final margin = net - cost;

    final body = rows.isEmpty
        ? EmptyHint(tr(context, 'No data in this period'),
            icon: Icons.savings_outlined)
        : ListView(
            padding: EdgeInsets.fromLTRB(20, embedded ? 8 : 12, 20, 28),
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
                        label: tr(context, 'Net sales'),
                        value: money(net),
                        icon: Icons.payments_rounded,
                      ),
                    ),
                    SizedBox(
                      width: w,
                      child: MetricTile(
                        label: tr(context, 'Cost'),
                        value: money(cost),
                        icon: Icons.savings_rounded,
                        accent: AppColors.danger,
                      ),
                    ),
                    SizedBox(
                      width: box.maxWidth,
                      child: MetricTile(
                        label: tr(context, 'Margin'),
                        value: money(margin),
                        icon: Icons.trending_up_rounded,
                        accent: AppColors.success,
                      ),
                    ),
                  ],
                );
              }),
              const SizedBox(height: 18),
              SectionTitle(tr(context, 'Costs & margins')),
              const SizedBox(height: 10),
              for (final e in rows) ...[
                OwnerCard(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(e.key,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.cairo(
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.navy)),
                            const SizedBox(height: 2),
                            Text(
                              'qty ${e.value.qty.toStringAsFixed(e.value.qty == e.value.qty.roundToDouble() ? 0 : 2)}'
                              ' · ${tr(context, 'Cost')} ${money(e.value.cost)}',
                              style: GoogleFonts.cairo(
                                  color: AppColors.muted,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        money(e.value.net - e.value.cost),
                        style: GoogleFonts.cairo(
                            fontWeight: FontWeight.w800,
                            color: AppColors.navy),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ],
            ],
          );

    if (embedded) return body;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Costs & margins'))),
      body: body,
    );
  }
}
