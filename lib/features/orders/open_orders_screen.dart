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
class OpenOrdersScreen extends StatefulWidget {
  const OpenOrdersScreen({
    super.key,
    required this.orders,
    required this.formatAmount,
    required this.onRecall,
    this.onCancel,
    this.onPrintBill,
    this.shiftOpen,
    this.onOpenShift,
  });

  /// Whether a cash-drawer shift is open, read on every build exactly as the floor
  /// and the counter read it. Null (the suites that only draw the list) gates
  /// nothing.
  ///
  /// Only picking a tab back up is gated, never looking: a recall used to land on
  /// the counter's refusal screen with no way forward, but a cashier with no shift
  /// still has every right to see what is parked.
  final bool Function()? shiftOpen;

  /// Opens the shift screen from this list's own refusal strip, and answers when the
  /// cashier comes back so the strip can go. Null hides the button rather than
  /// showing one that goes nowhere.
  final Future<void> Function()? onOpenShift;

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
  State<OpenOrdersScreen> createState() => _OpenOrdersScreenState();
}

class _OpenOrdersScreenState extends State<OpenOrdersScreen> {
  /// Showing only the deliveries. Off by default: this list is a floor's open
  /// tabs first, and a shop that does no delivery never sees the filter at all.
  bool _deliveryOnly = false;

  /// No shift, no recall. Read per build, exactly as the floor and the counter read
  /// it, so opening one and coming straight back lifts the block with no restart.
  bool get _noShift => widget.shiftOpen != null && !widget.shiftOpen!();

  String get _noShiftMessage => tr(context,
      'No shift is open. Open one before you pick a tab back up.');

  /// Why a parked tab cannot be picked up right now, said on the list instead of on
  /// the counter the recall used to land on. The list underneath stays readable and
  /// the bill can still be printed: neither is selling.
  Widget _noShiftStrip() => Material(
        key: const Key('open-orders-no-shift'),
        color: AppColors.error,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(children: [
            const Icon(Icons.point_of_sale, size: 18, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(
              child:
                  Text(_noShiftMessage, style: const TextStyle(color: Colors.white)),
            ),
            if (widget.onOpenShift != null)
              FilledButton(
                key: const Key('open-orders-open-shift'),
                style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: AppColors.error),
                onPressed: () async {
                  await widget.onOpenShift!();
                  // The shift screen sits on top of this list, so coming back has to
                  // re-read the drawer or the strip would stand over an open shift.
                  if (mounted) setState(() {});
                },
                child: Text(tr(context, 'Open shift')),
              ),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    // Deliveries are the orders with nowhere to be tapped on the floor plan, so
    // this is the only place they can be looked over as a group: who is waiting,
    // how long they have been waiting, and who is carrying them. Not a dispatch
    // board, and it holds no state of its own; it is a view of the same tabs.
    final anyDelivery =
        widget.orders.any((o) => o.type == OrderType.delivery);
    // The filter is dropped the moment the last delivery leaves the list: a cashier
    // must never be left staring at an empty screen whose only way back has just
    // disappeared with it.
    final shown = _deliveryOnly && anyDelivery
        ? widget.orders.where((o) => o.type == OrderType.delivery).toList()
        : widget.orders;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Open orders'))),
      body: Column(children: [
        if (_noShift) _noShiftStrip(),
        if (anyDelivery)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Wrap(spacing: 8, children: [
                ChoiceChip(
                  key: const Key('open-filter-all'),
                  label: Text(tr(context, 'All')),
                  selected: !_deliveryOnly,
                  onSelected: (_) => setState(() => _deliveryOnly = false),
                ),
                ChoiceChip(
                  key: const Key('open-filter-delivery'),
                  avatar: const Icon(Icons.delivery_dining, size: 16),
                  label: Text(tr(context, 'Delivery')),
                  selected: _deliveryOnly,
                  onSelected: (_) => setState(() => _deliveryOnly = true),
                ),
              ]),
            ),
          ),
        Expanded(
          child: shown.isEmpty
              ? Center(child: Text(tr(context, 'No open tables')))
              : ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: shown.length,
                  itemBuilder: (_, i) => _OpenOrderCard(
                    order: shown[i],
                    formatAmount: widget.formatAmount,
                    onPrintBill: widget.onPrintBill == null
                        ? null
                        : () {
                            widget.onPrintBill!(shown[i]);
                            showToast(context, tr(context, 'Bill sent to the printer'),
                                kind: ToastKind.success, key: const Key('bill-printed'));
                          },
                    onTap: () {
                      // Refused here, where the strip above says how to fix it,
                      // rather than by landing on a counter that can neither ring
                      // nor settle and offers nothing.
                      if (_noShift) {
                        showToast(context, _noShiftMessage, kind: ToastKind.error);
                        return;
                      }
                      widget.onRecall(shown[i]);
                      Navigator.of(context).pop();
                    },
                    onCancel: widget.onCancel == null
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
                                      style: FilledButton.styleFrom(
                                          backgroundColor: AppColors.error),
                                      onPressed: () => Navigator.pop(ctx, true),
                                      child: Text(tr(ctx, 'Discard'))),
                                ],
                              ),
                            );
                            if (ok == true) await widget.onCancel!(shown[i]);
                          },
                  ),
                ),
        ),
      ]),
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
      order.tableLabel ??
      (order.type == OrderType.delivery && order.customerName != null
          ? order.customerName!
          : '${tr(context, 'Tab')} ${order.displayNo}');

  /// How long this order has been sitting, which on a delivery is the number that
  /// matters: a bag rung forty minutes ago and still here is a phone call coming.
  String _age(BuildContext context) {
    final minutes = DateTime.now().toUtc().difference(order.createdAt).inMinutes;
    if (minutes < 1) return tr(context, 'just now');
    if (minutes < 60) return '$minutes${tr(context, 'm')}';
    return '${minutes ~/ 60}${tr(context, 'h')} ${minutes % 60}${tr(context, 'm')}';
  }

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
    final delivery = order.type == OrderType.delivery;
    final subtitleParts = <String>[
      tr(context, order.type.label),
      if (order.guestCount != null) '${order.guestCount} guests',
      // A delivery is read by who is carrying it and how long it has been here,
      // not by who rang it up.
      if (delivery && order.deliveryChannel != null) order.deliveryChannel!,
      if (delivery)
        order.driverName ?? tr(context, 'No driver yet')
      else
        order.cashierId,
      delivery ? '$_time (${_age(context)})' : _time,
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
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    if (preview.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
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
