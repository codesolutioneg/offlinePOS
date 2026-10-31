import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../l10n.dart';
import '../orders.dart';
import '../theme.dart';
import '../widgets/owner_ui.dart';

class OrderDetailScreen extends StatelessWidget {
  const OrderDetailScreen({super.key, required this.order});

  final OwnerOrder order;

  @override
  Widget build(BuildContext context) {
    final o = order;
    final at = o.createdAt.toLocal();
    final when =
        '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')} '
        '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';

    return Scaffold(
      appBar: AppBar(
          title: Text('${tr(context, 'Order detail')} #${o.displayNo}')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        children: [
          OwnerCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(money(o.total),
                    style: GoogleFonts.cairo(
                        fontSize: 32,
                        fontWeight: FontWeight.w800,
                        color: AppColors.navy,
                        height: 1.1,
                        letterSpacing: -0.8)),
                const SizedBox(height: 4),
                Text(o.state,
                    style: GoogleFonts.cairo(
                        color: AppColors.muted, fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                KvRow('When', when),
                KvRow(tr(context, 'Cashier'), o.cashierId),
                if (o.tableLabel != null && o.tableLabel!.isNotEmpty)
                  KvRow(tr(context, 'Table'), o.tableLabel!),
                if (o.customerName != null && o.customerName!.isNotEmpty)
                  KvRow('Customer', o.customerName!),
              ],
            ),
          ),
          const SizedBox(height: 12),
          OwnerCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SectionTitle(tr(context, 'Lines')),
                const SizedBox(height: 8),
                for (final l in o.lines) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${l.quantity} × ${l.name}',
                                  style: GoogleFonts.cairo(
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.navy)),
                              if (l.discountPercent > 0)
                                Text(
                                    '${tr(context, 'Discount')} ${l.discountPercent}%',
                                    style: GoogleFonts.cairo(
                                        color: AppColors.muted,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                        Text(money(l.total),
                            style: GoogleFonts.cairo(
                                fontWeight: FontWeight.w800)),
                      ],
                    ),
                  ),
                ],
                if (o.discountPercent > 0)
                  KvRow(
                    '${tr(context, 'Discount')} (${o.discountReason ?? o.discountPercent}%)',
                    '- ${money(o.checkDiscount)}',
                  ),
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
                if (o.payments.isEmpty)
                  KvRow('Cash', money(o.total))
                else
                  for (final p in o.payments)
                    KvRow(p.label ?? 'Cash', money(p.amount)),
                const SizedBox(height: 6),
                KvRow(tr(context, 'Total'), money(o.total), emphasize: true),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
