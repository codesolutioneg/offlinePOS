import 'package:flutter/material.dart';

import '../../domain/order.dart';

/// Past orders: what a cashier opens to answer "what did that table actually
/// order" or "can you reprint that receipt" after the sale is already done.
///
/// Everything shown here is read from the order already on disk. There is no
/// recomputation of totals or payments, because a history screen that shows a
/// different total than the receipt that was handed over is worse than one
/// that shows nothing.
class OrderHistoryScreen extends StatelessWidget {
  const OrderHistoryScreen({
    super.key,
    required this.orders,
    required this.formatAmount,
    required this.onReprint,
    this.onRefund,
  });

  /// Already sorted newest first by the caller (recent()); this screen does
  /// not re-sort, so a caller that wants a different order gets it.
  final List<Order> orders;
  final String Function(double) formatAmount;

  /// Reprints the receipt for [order]. Awaited so the confirmation snackbar
  /// only fires once the job has actually been handed to the printer.
  final Future<void> Function(Order order) onReprint;

  /// Opens the refund flow for [order]. Absent hides the refund action.
  final Future<void> Function(Order order)? onRefund;

  /// The first six hex characters of the uuid, upper-cased. Not unique on its
  /// own across a long history, but enough for a cashier to read a table's
  /// sale back to a customer without spelling out a full uuid.
  static String shortRef(String uuid) =>
      uuid.replaceAll('-', '').substring(0, 6).toUpperCase();

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Order history')),
        body: orders.isEmpty
            ? const Center(child: Text('No orders yet'))
            : ListView.separated(
                itemCount: orders.length,
                separatorBuilder: (context, index) => const Divider(height: 1),
                itemBuilder: (context, i) => _HistoryTile(
                  key: Key('history-${orders[i].uuid}'),
                  order: orders[i],
                  formatAmount: formatAmount,
                  onReprint: onReprint,
                  onRefund: onRefund,
                ),
              ),
      );
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({
    super.key,
    required this.order,
    required this.formatAmount,
    required this.onReprint,
    this.onRefund,
  });

  final Order order;
  final String Function(double) formatAmount;
  final Future<void> Function(Order order) onReprint;
  final Future<void> Function(Order order)? onRefund;

  /// synced: the server has it. paid: tendered but still queued. Nothing else
  /// reaches this screen, since a draft or held order was never a completed
  /// sale.
  String? get _syncBadge => switch (order.state) {
        OrderState.synced => 'synced',
        OrderState.paid => 'queued',
        OrderState.draft || OrderState.held => null,
      };

  @override
  Widget build(BuildContext context) {
    final local = order.createdAt.toLocal();
    final time =
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    final badge = _syncBadge;
    return ListTile(
      title: Text(
          '$time  ${OrderHistoryScreen.shortRef(order.uuid)}  ${formatAmount(order.total)}'),
      subtitle: Text(order.type.label),
      trailing: badge == null
          ? null
          : Chip(
              label: Text(badge),
              visualDensity: VisualDensity.compact,
            ),
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => OrderDetailScreen(
          order: order,
          formatAmount: formatAmount,
          onReprint: onReprint,
          onRefund: onRefund,
        ),
      )),
    );
  }
}

/// The detail view for a single completed sale: every line, every modifier,
/// the adjustments that moved the total, and a way to reprint the receipt
/// without re-ringing the sale.
class OrderDetailScreen extends StatelessWidget {
  const OrderDetailScreen({
    super.key,
    required this.order,
    required this.formatAmount,
    required this.onReprint,
    this.onRefund,
  });

  final Order order;
  final String Function(double) formatAmount;
  final Future<void> Function(Order order) onReprint;
  final Future<void> Function(Order order)? onRefund;

  Future<void> _reprint(BuildContext context) async {
    await onReprint(order);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Receipt sent to printer')),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            title: Text('Order ${OrderHistoryScreen.shortRef(order.uuid)}')),
        body: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            for (final line in order.lines) _lineTile(line),
            const Divider(),
            if (order.discountPercent > 0)
              _adjustmentRow('Discount', '-${order.discountPercent.toStringAsFixed(0)}%'),
            if (order.deliveryCost != 0)
              _adjustmentRow('Delivery', formatAmount(order.deliveryCost)),
            if (order.tip != 0) _adjustmentRow('Tip', formatAmount(order.tip)),
            const Divider(),
            Row(children: [
              const Text('TOTAL', style: TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              Text(formatAmount(order.total),
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 12),
            const Text('Payment', style: TextStyle(fontWeight: FontWeight.bold)),
            for (final p in order.payments)
              Row(children: [
                Expanded(child: Text(p.label ?? 'Cash')),
                Text(formatAmount(p.amount)),
              ]),
            const SizedBox(height: 20),
            FilledButton(
              key: Key('reprint-${order.uuid}'),
              onPressed: () => _reprint(context),
              child: const Text('Reprint receipt'),
            ),
            // A refund is offered only on a real sale, never on a refund itself, so
            // a return cannot be refunded again.
            if (onRefund != null && !order.isRefund) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: Key('refund-${order.uuid}'),
                onPressed: () => onRefund!(order),
                icon: const Icon(Icons.undo),
                label: const Text('Refund'),
              ),
            ],
          ],
        ),
      );

  Widget _lineTile(OrderLine line) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                  child: Text(
                      '${line.quantity.toStringAsFixed(line.quantity == line.quantity.roundToDouble() ? 0 : 3)} x ${line.name}')),
              Text(formatAmount(line.total)),
            ]),
            for (final m in line.modifiers)
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Text('+ ${m.name}',
                    style: const TextStyle(fontSize: 12, color: Colors.black54)),
              ),
            if (line.note != null)
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Text(line.note!,
                    style: const TextStyle(
                        fontSize: 12, fontStyle: FontStyle.italic, color: Colors.black54)),
              ),
          ],
        ),
      );

  Widget _adjustmentRow(String label, String value) => Row(children: [
        Expanded(child: Text(label)),
        Text(value),
      ]);
}
