import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
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
    required this.actingCashierId,
    required this.deviceId,
  });

  final Order original;
  final String Function(double) formatAmount;
  final void Function(Order refund) onRefund;

  /// The cashier processing the refund and the till it is processed on, so the
  /// money-out is booked and audited against whoever actually gave it back, not the
  /// cashier who rang the original sale (possibly on another device).
  final String actingCashierId;
  final String deviceId;

  @override
  State<RefundScreen> createState() => _RefundScreenState();
}

class _RefundScreenState extends State<RefundScreen> {
  // How much of each original line to refund, keyed by the line uuid. Doubles, so
  // a weighed line (e.g. 1.5 kg) refunds its exact quantity rather than a rounded
  // whole number.
  late final Map<String, double> _qty = {
    for (final l in widget.original.lines) l.uuid: l.quantity,
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
    // The whole-order discount and the bill's service charge applied proportionally, so
    // a refund returns what was actually paid rather than the pre-discount,
    // pre-service price.
    final o = widget.original;
    return t * o.discountFactor * o.serviceChargeFactor;
  }

  bool get _anySelected => _qty.values.any((q) => q > 0);

  static String _fmtQty(double q) =>
      q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(2);

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
        // Carry the tax rate so the refund books (and reports) the tax it reverses,
        // rather than treating the returned money as untaxed.
        taxRate: l.taxRate,
        modifiers: l.modifiers,
      ));
    }
    // Return the money on the tenders it came in on, so the refund is not silently
    // booked to cash and a split sale reverses each method in proportion. Negative
    // amounts are money going back out; they sum to the refunded value. Dividing by
    // the tendered sum keeps this correct for partial refunds and legacy rows whose
    // payment amount held the cash tendered.
    final tendered = o.payments.fold<double>(0.0, (s, p) => s + p.amount);
    final refundPayments = (o.payments.isEmpty || tendered <= 0)
        ? const <OrderPayment>[]
        : [
            for (final p in o.payments)
              OrderPayment(
                  methodId: p.methodId,
                  amount: -(_refundTotal * p.amount / tendered),
                  label: p.label),
          ];
    final refund = Order(
      deviceId: widget.deviceId,
      cashierId: widget.actingCashierId,
      type: o.type,
      partnerId: o.partnerId,
      customerName: o.customerName,
      discountPercent: o.discountPercent,
      // The credit carries the service the original bill charged, so a return gives back
      // the service on the returned items too rather than keeping it.
      serviceChargePercent: o.serviceChargePercent,
      note: 'Refund of #${_shortRef(o)}: $reason',
      lines: lines,
      payments: refundPayments,
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
      appBar: AppBar(title: Text('${tr(context, 'Refund')} #${_shortRef(o)}')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              children: [
                for (final l in o.lines)
                  ListTile(
                    key: Key('refund-line-${l.uuid}'),
                    title: Text(l.name),
                    subtitle: Text('${tr(context, 'Sold')} ${_fmtQty(l.quantity)} @ '
                        '${widget.formatAmount(l.unitPrice)}'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        icon: const Icon(Icons.remove_circle_outline, size: 28),
                        // Step by whole units, but never below zero; a weighed line's
                        // remaining fraction drops to zero on the last step.
                        onPressed: (_qty[l.uuid] ?? 0) > 0
                            ? () => setState(() =>
                                _qty[l.uuid] = (_qty[l.uuid]! - 1).clamp(0, l.quantity))
                            : null,
                      ),
                      Text(_fmtQty(_qty[l.uuid] ?? 0),
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      IconButton(
                        icon: const Icon(Icons.add_circle_outline, size: 28),
                        onPressed: (_qty[l.uuid] ?? 0) < l.quantity
                            ? () => setState(() =>
                                _qty[l.uuid] = (_qty[l.uuid]! + 1).clamp(0, l.quantity))
                            : null,
                      ),
                    ]),
                  ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextField(
                    key: const Key('refund-reason'),
                    controller: _reason,
                    decoration: InputDecoration(
                        labelText: tr(context, 'Reason for refund'),
                        border: const OutlineInputBorder()),
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
                  child: Text(
                      '${tr(context, 'Refund')} ${widget.formatAmount(_refundTotal)}',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
                FilledButton.icon(
                  key: const Key('confirm-refund'),
                  style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
                  onPressed: (_anySelected && _reason.text.trim().isNotEmpty) ? _confirm : null,
                  icon: const Icon(Icons.undo),
                  label: Text(tr(context, 'Refund')),
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
