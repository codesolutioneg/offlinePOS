import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../core/widgets/feedback.dart';
import '../../domain/order.dart';

/// Past orders: what a cashier opens to answer "what did that table actually
/// order" or "can you reprint that receipt" after the sale is already done.
///
/// Everything shown here is read from the order already on disk. There is no
/// recomputation of totals or payments, because a history screen that shows a
/// different total than the receipt that was handed over is worse than one
/// that shows nothing.
class OrderHistoryScreen extends StatefulWidget {
  const OrderHistoryScreen({
    super.key,
    required this.orders,
    required this.formatAmount,
    required this.onReprint,
    this.onRefund,
    this.onEdit,
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

  /// Puts [order] back on the counter to be corrected. Absent hides the action,
  /// and so does the order being anything but a paid sale this till still holds:
  /// see [OrderDetailScreen.canEdit].
  final Future<void> Function(Order order)? onEdit;

  /// The first six hex characters of the uuid, upper-cased. Not unique on its
  /// own across a long history, but enough for a cashier to read a table's
  /// sale back to a customer without spelling out a full uuid.
  static String shortRef(String uuid) =>
      uuid.replaceAll('-', '').substring(0, 6).toUpperCase();

  @override
  State<OrderHistoryScreen> createState() => _OrderHistoryScreenState();
}

class _OrderHistoryScreenState extends State<OrderHistoryScreen> {
  String _search = '';
  OrderType? _type; // null = any
  bool _syncedOnly = false;
  int _days = 0; // 0 = all, else last N days by local date

  /// Orders matching the search box (ref / table / customer) and the filters.
  List<Order> get _filtered {
    final q = _search.trim().toLowerCase();
    final now = DateTime.now();
    final startOfToday = DateTime(now.year, now.month, now.day);
    return widget.orders.where((o) {
      if (_type != null && o.type != _type) return false;
      if (_syncedOnly && o.state != OrderState.synced) return false;
      if (_days > 0) {
        final cutoff = startOfToday.subtract(Duration(days: _days - 1));
        if (o.createdAt.toLocal().isBefore(cutoff)) return false;
      }
      if (q.isEmpty) return true;
      return OrderHistoryScreen.shortRef(o.uuid).toLowerCase().contains(q) ||
          (o.tableLabel ?? '').toLowerCase().contains(q) ||
          (o.customerName ?? '').toLowerCase().contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _filtered;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Order history'))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              key: const Key('history-search'),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: tr(context, 'Search ref, table or customer'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _search = v),
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                ChoiceChip(
                  key: const Key('history-type-all'),
                  label: Text(tr(context, 'All')),
                  selected: _type == null,
                  onSelected: (_) => setState(() => _type = null),
                ),
                for (final t in OrderType.values) ...[
                  const SizedBox(width: 6),
                  ChoiceChip(
                    key: Key('history-type-${t.name}'),
                    label: Text(tr(context, t.label)),
                    selected: _type == t,
                    onSelected: (_) => setState(() => _type = t),
                  ),
                ],
                const SizedBox(width: 6),
                FilterChip(
                  key: const Key('history-synced'),
                  label: Text(tr(context, 'Synced only')),
                  selected: _syncedOnly,
                  onSelected: (v) => setState(() => _syncedOnly = v),
                ),
                const SizedBox(width: 12),
                for (final d in const [(0, 'All'), (1, 'Today'), (7, 'Last 7 days'), (30, 'Last 30 days')]) ...[
                  const SizedBox(width: 6),
                  ChoiceChip(
                    key: Key('history-days-${d.$1}'),
                    label: Text(tr(context, d.$2)),
                    selected: _days == d.$1,
                    onSelected: (_) => setState(() => _days = d.$1),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: shown.isEmpty
                ? EmptyState(
                    icon: Icons.receipt_long_outlined,
                    title: tr(context, 'No orders yet'),
                    message: tr(context, 'Completed sales will show up here'),
                  )
                : ListView.separated(
                    itemCount: shown.length,
                    separatorBuilder: (context, index) => const Divider(height: 1),
                    itemBuilder: (context, i) => _HistoryTile(
                      key: Key('history-${shown[i].uuid}'),
                      order: shown[i],
                      formatAmount: widget.formatAmount,
                      onReprint: widget.onReprint,
                      onRefund: widget.onRefund,
                      onEdit: widget.onEdit,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({
    super.key,
    required this.order,
    required this.formatAmount,
    required this.onReprint,
    this.onRefund,
    this.onEdit,
  });

  final Order order;
  final String Function(double) formatAmount;
  final Future<void> Function(Order order) onReprint;
  final Future<void> Function(Order order)? onRefund;
  final Future<void> Function(Order order)? onEdit;

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
      subtitle: Text(tr(context, order.type.label)),
      trailing: badge == null
          ? null
          : Chip(
              label: Text(tr(context, badge)),
              visualDensity: VisualDensity.compact,
            ),
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => OrderDetailScreen(
          order: order,
          formatAmount: formatAmount,
          onReprint: onReprint,
          onRefund: onRefund,
          onEdit: onEdit,
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
    this.onEdit,
  });

  final Order order;
  final String Function(double) formatAmount;
  final Future<void> Function(Order order) onReprint;
  final Future<void> Function(Order order)? onRefund;
  final Future<void> Function(Order order)? onEdit;

  /// Whether [o] can still be corrected on the till rather than reversed.
  ///
  /// Only a sale that is tendered but not yet acknowledged by the server, and is
  /// not itself a refund. Once the server has it a repeat of its uuid reads there
  /// as a duplicate of what was already booked rather than as a correction, so the
  /// answer past that point is a refund and a re-ring. The store refuses the same
  /// cases; this only keeps the till from offering what it would then refuse.
  static bool canEdit(Order o) =>
      o.state == OrderState.paid && !o.isRefund;

  Future<void> _reprint(BuildContext context) async {
    await onReprint(order);
    if (!context.mounted) return;
    showToast(context, tr(context, 'Receipt sent to printer'), kind: ToastKind.success);
  }

  /// Reverse the whole sale rather than delete it, so the books stay append-only:
  /// the original stands and a full-quantity refund is booked against it. The
  /// refund screen already opens with every line selected, so this is the same
  /// flow with the intent said out loud and confirmed first.
  Future<void> _cancelSale(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(ctx, 'Cancel this sale?')),
        content: Text(tr(
            ctx,
            'The sale stays on the books and a full refund is recorded against '
            'it. Pick the lines and give a reason on the next screen.')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr(ctx, 'Keep the sale'))),
          FilledButton(
            key: const Key('cancel-sale-ok'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr(ctx, 'Refund it all')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await onRefund!(order);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            title: Text(
                '${tr(context, 'Order')} ${OrderHistoryScreen.shortRef(order.uuid)}')),
        body: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            for (final line in order.lines) _lineTile(line),
            const Divider(),
            if (order.discountPercent > 0)
              _adjustmentRow(tr(context, 'Discount'),
                  '-${order.discountPercent.toStringAsFixed(0)}%'),
            if (order.serviceChargePercent > 0)
              _adjustmentRow(tr(context, 'Service'), formatAmount(order.serviceCharge)),
            if (order.deliveryCost != 0)
              _adjustmentRow(tr(context, 'Delivery'), formatAmount(order.deliveryCost)),
            if (order.tip != 0) _adjustmentRow(tr(context, 'Tip'), formatAmount(order.tip)),
            const Divider(),
            Row(children: [
              Text(tr(context, 'TOTAL'), style: const TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              Text(formatAmount(order.total),
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 12),
            Text(tr(context, 'Payment'), style: const TextStyle(fontWeight: FontWeight.bold)),
            for (final p in order.payments)
              Row(children: [
                Expanded(child: Text(p.label ?? tr(context, 'Cash'))),
                Text(formatAmount(p.amount)),
              ]),
            const SizedBox(height: 20),
            FilledButton(
              key: Key('reprint-${order.uuid}'),
              onPressed: () => _reprint(context),
              child: Text(tr(context, 'Reprint receipt')),
            ),
            // Correcting the sale is offered first, because it is what a cashier
            // who rang it wrong actually wants; the money-back routes are below it.
            if (onEdit != null && canEdit(order)) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: Key('edit-${order.uuid}'),
                onPressed: () => onEdit!(order),
                icon: const Icon(Icons.edit_outlined),
                label: Text(tr(context, 'Edit order')),
              ),
            ],
            // A refund is offered only on a real sale, never on a refund itself, so
            // a return cannot be refunded again.
            if (onRefund != null && !order.isRefund) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: Key('refund-${order.uuid}'),
                onPressed: () => onRefund!(order),
                icon: const Icon(Icons.undo),
                label: Text(tr(context, 'Refund')),
              ),
              // The whole sale back, for the till's other answer to "that was
              // wrong": one confirmation instead of stepping every line down.
              // Offered on the same orders Edit is, since a sale the server has
              // already booked is refunded through the line picker like any other.
              if (canEdit(order)) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: Key('cancel-sale-${order.uuid}'),
                  onPressed: () => _cancelSale(context),
                  icon: const Icon(Icons.block_outlined),
                  label: Text(tr(context, 'Cancel sale')),
                ),
              ],
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
