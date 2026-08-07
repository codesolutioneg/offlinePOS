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

  Uint8List build(Order order) {
    final p = EscPos(columns: columns)..reset();

    p.align(EscPosAlign.center)
      ..size(doubleWidth: true, doubleHeight: true)
      ..bold(true)
      ..line(shopName)
      ..bold(false)
      ..size();
    if (taxId != null) p.line(taxId!);
    p.align(EscPosAlign.left).rule();

    p.line('${_stamp(order.createdAt)}  #${_shortRef(order)}');
    p.line('Cashier: ${order.cashierId}');
    p.rule();

    for (final l in order.lines) {
      p.row('${_qty(l.quantity)} x ${l.name}', formatAmount(l.quantity * l.unitPrice));
      for (final m in l.modifiers) {
        // Modifiers are indented so the kitchen and the customer both read the
        // line they belong to. Free ones show no amount at all.
        final amount = m.unitPrice == 0
            ? ''
            : formatAmount(l.quantity * m.total);
        p.row('   + ${m.name}${m.quantity > 1 ? ' x${_qty(m.quantity)}' : ''}', amount);
      }
    }

    p.rule();
    p.size(doubleHeight: true).bold(true)
      ..row('TOTAL', formatAmount(order.total))
      ..bold(false)
      ..size();

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

  String _stamp(DateTime utc) {
    final d = utc.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}
