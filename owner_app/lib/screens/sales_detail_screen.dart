import 'package:flutter/material.dart';

import '../l10n.dart';
import '../orders.dart';
import '../theme.dart';
import '../widgets/owner_ui.dart';

class SalesDetailScreen extends StatelessWidget {
  const SalesDetailScreen({
    super.key,
    required this.orders,
    this.onOpen,
  });

  final List<OwnerOrder> orders;
  final void Function(OwnerOrder order)? onOpen;

  @override
  Widget build(BuildContext context) {
    final list = [...orders]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Sales detail'))),
      body: list.isEmpty
          ? EmptyHint(tr(context, 'No data in this period'))
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
              itemCount: list.length,
              itemBuilder: (context, i) {
                final o = list[i];
                final at = o.createdAt.toLocal();
                final when =
                    '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')} '
                    '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: OrderListCard(
                    title: '#${o.displayNo}',
                    subtitle:
                        '$when · ${o.orderType}${o.tableLabel == null || o.tableLabel!.isEmpty ? '' : ' · ${o.tableLabel}'}',
                    amount: money(o.total),
                    leadingIcon: o.isRefund
                        ? Icons.undo_rounded
                        : Icons.receipt_long_rounded,
                    accent: o.isRefund ? AppColors.danger : AppColors.skyDark,
                    onTap: onOpen == null ? null : () => onOpen!(o),
                  ),
                );
              },
            ),
    );
  }
}
