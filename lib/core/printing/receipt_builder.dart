import 'dart:typed_data';

import '../../domain/order.dart';
import 'escpos.dart';

/// Formats an order as printer bytes.
///
/// Amount formatting is injected so this stays free of locale and currency
/// assumptions: the caller owns how money looks, this owns how the receipt is laid
/// out.
class ReceiptBuilder {
  ReceiptBuilder({
    required this.shopName,
    required this.formatAmount,
    this.columns = 42,
    this.footer,
    this.taxId,
  });

  final String shopName;
  final String Function(double) formatAmount;
  final int columns;
  final String? footer;
  final String? taxId;

  Uint8List build(Order order, {bool reprint = false}) {
    final p = EscPos(columns: columns)..reset();

    p.align(EscPosAlign.center)
      ..size(doubleWidth: true, doubleHeight: true)
      ..bold(true)
      ..line(shopName)
      ..bold(false)
      ..size();
    if (taxId != null) p.line(taxId!);
    // A reprint is marked so a duplicate slip cannot be passed off as a second sale.
    if (reprint) p.centred('*** REPRINT ***');
    p.align(EscPosAlign.left).rule();

    // Where the sale was served, so a delivery or table sale reads differently
    // from a counter one on the same roll.
    p.line(order.type.label + (order.tableLabel != null ? '  Table ${order.tableLabel}' : ''));
    if (order.guestCount != null) p.line('Guests: ${order.guestCount}');
    p.line('${_stamp(order.createdAt)}  #${_shortRef(order)}');
    p.line('Cashier: ${order.cashierId}');
    if (order.customerName != null) p.line('Customer: ${order.customerName}');
    p.rule();

    for (final l in order.lines) {
      // The line total is net of any per-line discount and includes its modifiers,
      // so what prints is what the customer is charged for that line.
      p.row('${_qty(l.quantity)} x ${l.name}', formatAmount(l.total));
      for (final m in l.modifiers) {
        // Modifiers are indented so the kitchen and the customer both read the
        // line they belong to. Free ones show no amount at all.
        final amount = m.unitPrice == 0 ? '' : formatAmount(l.quantity * m.total);
        p.row('   + ${m.name}${m.quantity > 1 ? ' x${_qty(m.quantity)}' : ''}', amount);
      }
      if (l.discountPercent > 0) {
        p.line('   (-${_pct(l.discountPercent)}% line discount)');
      }
      if (l.note != null && l.note!.isNotEmpty) p.line('   ${l.note}');
    }

    p.rule();
    // Show the breakdown only when there is one, so a plain sale stays a plain
    // receipt but a discounted delivery with a tip is fully itemised.
    final hasBreakdown = order.discountPercent > 0 ||
        order.deliveryCost > 0 ||
        order.tip > 0;
    if (hasBreakdown) {
      p.row('Subtotal', formatAmount(order.subtotal));
      if (order.discountPercent > 0) {
        final label = order.discountReason == null
            ? 'Discount ${_pct(order.discountPercent)}%'
            : 'Discount ${_pct(order.discountPercent)}% (${order.discountReason})';
        p.row(label, '-${formatAmount(order.subtotal * order.discountPercent / 100)}');
      }
      if (order.deliveryCost > 0) p.row('Delivery', formatAmount(order.deliveryCost));
      if (order.tip > 0) p.row('Tip', formatAmount(order.tip));
    }
    p.size(doubleHeight: true).bold(true)
      ..row('TOTAL', formatAmount(order.total))
      ..bold(false)
      ..size();

    // Tender breakdown and change. A split payment prints one line per tender; a
    // cash overpayment prints the change the customer is owed.
    if (order.payments.isNotEmpty) {
      p.feed();
      var tendered = 0.0;
      for (final pay in order.payments) {
        tendered += pay.amount;
        p.row(pay.label ?? 'Payment', formatAmount(pay.amount));
      }
      final change = tendered - order.total;
      if (change > 0.001) p.row('Change', formatAmount(change));
    }

    if (footer != null) {
      p.feed().align(EscPosAlign.center).line(footer!);
    }
    return (p..feed(2)..cut()).build();
  }

  /// The order's own reference: the tail of the client uuid, which is stable and
  /// unique without needing the server to hand out a number.
  String _shortRef(Order o) =>
      o.uuid.replaceAll('-', '').substring(0, 6).toUpperCase();

  String _qty(double q) =>
      q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(3);

  /// A percentage printed without trailing zeros: 12.5 stays 12.5, 10.0 shows 10.
  String _pct(double p) =>
      p == p.roundToDouble() ? p.toStringAsFixed(0) : p.toStringAsFixed(1);

  String _stamp(DateTime utc) {
    final d = utc.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}
