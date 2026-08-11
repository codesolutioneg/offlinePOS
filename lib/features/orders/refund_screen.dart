import 'package:flutter/material.dart';

import '../../domain/order.dart';

/// Refund some or all of a past sale. The cashier picks how many of each line to
/// return and why; the screen builds a refund order (negative quantities, linked to
/// the original by uuid) which the caller records, prints and queues.
///
/// This is a real money-returning transaction, distinct from voiding a line before
/// payment: the sale already happened, so the reversal is auditable and books a
/// credit against the original.
class RefundScreen extends StatefulWidget {
  const RefundScreen({
    super.key,
    required this.original,
    required this.formatAmount,
    required this.onRefund,
  });

  final Order original;
  final String Function(double) formatAmount;
  final void Function(Order refund) onRefund;

  @override
  State<RefundScreen> createState() => _RefundScreenState();
}

class _RefundScreenState extends State<RefundScreen> {
  // How many of each original line to refund, keyed by the line uuid.
  late final Map<String, int> _qty = {
    for (final l in widget.original.lines) l.uuid: l.quantity.round(),
  };
  final TextEditingController _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  double get _refundTotal {
    var t = 0.0;
    for (final l in widget.original.lines) {
      final q = _qty[l.uuid] ?? 0;
      if (q <= 0) continue;
      // Per-unit line value (net of its own discount), times the refunded count.
      final perUnit = l.total / (l.quantity == 0 ? 1 : l.quantity);
      t += perUnit * q;
    }
    // The whole-order discount applied proportionally, so a refund returns what was
    // actually paid, not the pre-discount price.
    return t * widget.original.discountFactor;
  }

  bool get _anySelected => _qty.values.any((q) => q > 0);

  void _confirm() {
    final reason = _reason.text.trim();
    if (reason.isEmpty || !_anySelected) return;
    final o = widget.original;
    final lines = <OrderLine>[];
    for (final l in o.lines) {
      final q = _qty[l.uuid] ?? 0;
      if (q <= 0) continue;
      lines.add(OrderLine(
        productId: l.productId,
        name: l.name,
        quantity: -q.toDouble(), // negative: this reverses the sale
        unitPrice: l.unitPrice,
        discountPercent: l.discountPercent,
        categoryId: l.categoryId,
        modifiers: l.modifiers,
      ));
    }
    final refund = Order(
      deviceId: o.deviceId,
      cashierId: o.cashierId,
      type: o.type,
      partnerId: o.partnerId,
      customerName: o.customerName,
      discountPercent: o.discountPercent,
      note: 'Refund of #${_shortRef(o)}: $reason',
      lines: lines,
    )
      ..refundOfUuid = o.uuid
      ..state = OrderState.paid;
    widget.onRefund(refund);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.original;
    return Scaffold(
      appBar: AppBar(title: Text('Refund #${_shortRef(o)}')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              children: [
                for (final l in o.lines)
                  ListTile(
                    key: Key('refund-line-${l.uuid}'),
                    title: Text(l.name),
                    subtitle: Text('Sold ${l.quantity.toStringAsFixed(0)} @ '
                        '${widget.formatAmount(l.unitPrice)}'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        icon: const Icon(Icons.remove_circle_outline),
                        onPressed: (_qty[l.uuid] ?? 0) > 0
                            ? () => setState(() => _qty[l.uuid] = (_qty[l.uuid]! - 1))
                            : null,
                      ),
                      Text('${_qty[l.uuid] ?? 0}'),
                      IconButton(
                        icon: const Icon(Icons.add_circle_outline),
                        onPressed: (_qty[l.uuid] ?? 0) < l.quantity.round()
                            ? () => setState(() => _qty[l.uuid] = (_qty[l.uuid]! + 1))
                            : null,
                      ),
                    ]),
                  ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextField(
                    key: const Key('refund-reason'),
                    controller: _reason,
                    decoration: const InputDecoration(
                        labelText: 'Reason for refund', border: OutlineInputBorder()),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                Expanded(
                  child: Text('Refund ${widget.formatAmount(_refundTotal)}',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
                FilledButton.icon(
                  key: const Key('confirm-refund'),
                  style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
                  onPressed: (_anySelected && _reason.text.trim().isNotEmpty) ? _confirm : null,
                  icon: const Icon(Icons.undo),
                  label: const Text('Refund'),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  String _shortRef(Order o) =>
      o.uuid.replaceAll('-', '').substring(0, 6).toUpperCase();
}
