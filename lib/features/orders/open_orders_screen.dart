import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
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
  });

  final List<Order> orders;
  final String Function(double) formatAmount;
  final void Function(Order order) onRecall;

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
                onTap: () {
                  onRecall(orders[i]);
                  Navigator.of(context).pop();
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
  });

  final Order order;
  final String Function(double) formatAmount;
  final VoidCallback onTap;

  // A tab with no table still needs a name a cashier can say out loud, so it
  // falls back to a short uuid tail rather than the full identifier.
  String get _shortUuid =>
      order.uuid.replaceAll('-', '').substring(0, 6).toUpperCase();

  String _label(BuildContext context) =>
      order.tableLabel ?? '${tr(context, 'Tab')} $_shortUuid';

  String get _time {
    final local = order.createdAt.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final itemCount = order.lines.length;
    final preview = order.lines.take(3).map((l) => l.name).join(', ');
    final label = _label(context);
    final subtitleParts = <String>[
      tr(context, order.type.label),
      if (order.guestCount != null) '${order.guestCount} guests',
      order.cashierId,
      _time,
    ];
    return Card(
      key: Key('open-order-${order.uuid}'),
      child: InkWell(
        key: Key('recall-${order.uuid}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
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
            ],
          ),
        ),
      ),
    );
  }
}
