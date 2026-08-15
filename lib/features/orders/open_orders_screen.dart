import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/feedback.dart';
import '../../domain/order.dart';

/// Lists orders parked on a table or tab so a cashier can pick one back up.
///
/// A held order is money already committed to the kitchen but not yet paid: it
/// must stay findable by table, not just by whoever remembers the uuid, because
/// the till is shared across shifts and cashiers do not recall each other's tabs.
class OpenOrdersScreen extends StatelessWidget {
  const OpenOrdersScreen({
    super.key,
    required this.orders,
    required this.formatAmount,
    required this.onRecall,
    this.onCancel,
    this.onPrintBill,
  });

  final List<Order> orders;
  final String Function(double) formatAmount;
  final void Function(Order order) onRecall;

  /// Discards a held order (abandoned tab). Manager-gated by the caller. Absent
  /// hides the cancel action.
  final Future<void> Function(Order order)? onCancel;

  /// Prints the check for a parked tab without recalling it, so a waiter can take the
  /// bill to the table straight from this list. Absent hides the action.
  final void Function(Order order)? onPrintBill;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Open orders'))),
      body: orders.isEmpty
          ? Center(child: Text(tr(context, 'No open tables')))
          : ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: orders.length,
              itemBuilder: (_, i) => _OpenOrderCard(
                order: orders[i],
                formatAmount: formatAmount,
                onPrintBill: onPrintBill == null
                    ? null
                    : () {
                        onPrintBill!(orders[i]);
                        showToast(context, tr(context, 'Bill sent to the printer'),
                            kind: ToastKind.success, key: const Key('bill-printed'));
                      },
                onTap: () {
                  onRecall(orders[i]);
                  Navigator.of(context).pop();
                },
                onCancel: onCancel == null
                    ? null
                    : () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: Text(tr(ctx, 'Cancel this order?')),
                            content: Text(tr(ctx,
                                'The parked order will be discarded. This cannot be undone.')),
                            actions: [
                              TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: Text(tr(ctx, 'Keep'))),
                              FilledButton(
                                  key: const Key('confirm-cancel-order'),
                                  style: FilledButton.styleFrom(backgroundColor: AppColors.error),
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: Text(tr(ctx, 'Discard'))),
                            ],
                          ),
                        );
                        if (ok == true) await onCancel!(orders[i]);
                      },
              ),
            ),
    );
  }
}

class _OpenOrderCard extends StatelessWidget {
  const _OpenOrderCard({
    required this.order,
    required this.formatAmount,
    required this.onTap,
    this.onCancel,
    this.onPrintBill,
  });

  final Order order;
  final String Function(double) formatAmount;
  final VoidCallback onTap;
  final VoidCallback? onCancel;
  final VoidCallback? onPrintBill;

  String _label(BuildContext context) =>
      order.tableLabel ?? '${tr(context, 'Tab')} ${order.displayNo}';

  String get _time {
    final local = order.createdAt.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  /// The tab's kitchen state as a label, colour and icon, so a glance down the list
  /// tells a cashier which tables are held, cooking or ready to run.
  (String, Color, IconData) _status(BuildContext context) => switch (order.kitchenStatus) {
        KitchenStatus.pending =>
          (tr(context, 'Held'), AppColors.held, Icons.pause_circle_outline),
        KitchenStatus.preparing =>
          (tr(context, 'Preparing'), AppColors.info, Icons.local_fire_department_outlined),
        KitchenStatus.ready =>
          (tr(context, 'Ready'), AppColors.success, Icons.check_circle_outline),
        KitchenStatus.served => (tr(context, 'Served'), Colors.grey, Icons.done_all),
      };

  @override
  Widget build(BuildContext context) {
    final itemCount = order.lines.length;
    final preview = order.lines.take(3).map((l) => l.name).join(', ');
    final label = _label(context);
    final (statusLabel, statusColor, statusIcon) = _status(context);
    final hasUnsent = order.lines.any((l) => !l.printedToKitchen);
    final subtitleParts = <String>[
      tr(context, order.type.label),
      if (order.guestCount != null) '${order.guestCount} guests',
      order.cashierId,
      _time,
    ];
    return Card(
      key: Key('open-order-${order.uuid}'),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: statusColor.withValues(alpha: 0.4)),
      ),
      child: InkWell(
        key: Key('recall-${order.uuid}'),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: statusColor, width: 5)),
          ),
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                backgroundColor: statusColor.withValues(alpha: 0.15),
                foregroundColor: statusColor,
                child: Text(label.length >= 2 ? label.substring(0, 2) : label),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(label,
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold)),
                        ),
                        Text(
                          '$itemCount item${itemCount == 1 ? '' : 's'}, '
                          '${formatAmount(order.total)}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(children: [
                      StatusChip(statusLabel, statusColor, icon: statusIcon),
                      if (hasUnsent) ...[
                        const SizedBox(width: 6),
                        StatusChip(tr(context, 'New items'), AppColors.draft,
                            icon: Icons.fiber_new),
                      ],
                    ]),
                    const SizedBox(height: 4),
                    Text(subtitleParts.join(' · '),
                        style: const TextStyle(color: Colors.black54)),
                    if (preview.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.black54)),
                    ],
                  ],
                ),
              ),
              // Printing the check does not recall the tab, so a waiter can walk a
              // bill to one table without taking the order off another cashier.
              if (onPrintBill != null && order.lines.isNotEmpty)
                IconButton(
                  key: Key('print-bill-${order.uuid}'),
                  tooltip: tr(context, 'Print bill'),
                  icon: const Icon(Icons.receipt_long_outlined),
                  onPressed: onPrintBill,
                ),
              if (onCancel != null)
                IconButton(
                  key: Key('cancel-order-${order.uuid}'),
                  tooltip: tr(context, 'Cancel order'),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: onCancel,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
