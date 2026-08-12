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
    this.header,
    this.showCashier = true,
    this.showOrderType = true,
    this.showTax = true,
    this.showDateTime = true,
    this.showNumber = true,
    this.showTable = true,
    this.showPayment = true,
    this.showItemPrice = true,
    this.dividerStyle = 'line',
    this.openDrawer = false,
  });

  final String shopName;
  final String Function(double) formatAmount;
  final int columns;
  final String? footer;
  final String? taxId;

  /// An optional line printed under the shop name (address, phone, slogan), set in
  /// the receipt designer.
  final String? header;

  /// Receipt-designer toggles.
  final bool showCashier;
  final bool showOrderType;
  final bool showTax;
  final bool showDateTime;
  final bool showNumber;
  final bool showTable;
  final bool showPayment;
  final bool showItemPrice;

  /// Which character separator lines are drawn with, as stored by the receipt
  /// designer. Anything unrecognised falls back to a dashed rule.
  final String dividerStyle;

  static const _dividerChars = {'line': '-', 'equals': '=', 'dots': '.', 'stars': '*'};

  /// Kick the cash drawer open at the end, for a cash sale.
  final bool openDrawer;

  Uint8List build(Order order, {bool reprint = false}) {
    final p = EscPos(columns: columns)..reset();
    final divider = _dividerChars[dividerStyle] ?? '-';

    p.align(EscPosAlign.center)
      ..size(doubleWidth: true, doubleHeight: true)
      ..bold(true)
      ..line(shopName)
      ..bold(false)
      ..size();
    if (header != null && header!.isNotEmpty) p.centred(header!);
    if (taxId != null) p.line(taxId!);
    // A reprint is marked so a duplicate slip cannot be passed off as a second sale.
    if (reprint) p.centred('*** REPRINT ***');
    p.align(EscPosAlign.left).rule(divider);

    // Where the sale was served, so a delivery or table sale reads differently
    // from a counter one on the same roll.
    if (showOrderType) p.line(order.type.label);
    // Table and covers, only for a dine-in that actually carries them: a counter
    // sale must never print "Table null".
    if (showTable && order.type == OrderType.dineIn) {
      final seating = [
        if (order.tableLabel != null) 'Table ${order.tableLabel}',
        if (order.guestCount != null) '${order.guestCount} guests',
      ].join(' - ');
      if (seating.isNotEmpty) p.line(seating);
    }
    // Time of sale and the order's own reference, each on its own toggle but sharing
    // a line when both print.
    final stamped = [
      if (showDateTime) _stamp(order.createdAt),
      if (showNumber) '#${_shortRef(order)}',
    ].join('  ');
    if (stamped.isNotEmpty) p.line(stamped);
    if (showCashier) p.line('Cashier: ${order.cashierId}');
    if (order.customerName != null) p.line('Customer: ${order.customerName}');
    p.rule(divider);

    for (final l in order.lines) {
      // The base price is printed on the header and each modifier's amount below it,
      // so the printed parts add up to the line total rather than counting the
      // modifiers twice. A per-line discount prints as its own negative line, so
      // header + modifiers - discount reconciles to what the customer pays.
      // With prices hidden the slip becomes a packing list: names and quantities
      // still print, the amount column does not.
      p.row('${_qty(l.quantity)} x ${l.name}',
          showItemPrice ? formatAmount(l.quantity * l.unitPrice) : '');
      for (final m in l.modifiers) {
        final amount =
            (!showItemPrice || m.unitPrice == 0) ? '' : formatAmount(l.quantity * m.total);
        p.row('   + ${m.name}${m.quantity > 1 ? ' x${_qty(m.quantity)}' : ''}', amount);
      }
      if (l.discountPercent > 0) {
        p.row('   line discount ${_pct(l.discountPercent)}%',
            '-${formatAmount(l.gross * l.discountPercent / 100)}');
      }
      if (l.note != null && l.note!.isNotEmpty) p.line('   ${l.note}');
    }

    p.rule(divider);
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
    // Tax is shown as included in the total (prices are tax-inclusive), so the
    // slip is a valid tax receipt without changing what the customer pays.
    final tax = order.taxTotal;
    if (showTax && tax > 0.001) {
      p.row('Net', formatAmount(order.total - tax));
      p.row('Tax', formatAmount(tax));
    }
    p.size(doubleHeight: true).bold(true)
      ..row('TOTAL', formatAmount(order.total))
      ..bold(false)
      ..size();

    // Tender breakdown and change. A split payment prints one line per tender.
    // Payments store the settled amount, so a cash overpayment prints the cash
    // received and the change owed from [cashReceived] rather than from the tender.
    if (order.payments.isNotEmpty) {
      p.feed();
      if (showPayment) {
        for (final pay in order.payments) {
          p.row(pay.label ?? 'Payment', formatAmount(pay.amount));
        }
      }
      // Orders stored before cash_received existed kept the tender in the payment
      // amount, so fall back to the payment sum for their reprints. New orders
      // settle to exactly the total, so this prints nothing unless there is change.
      final received = order.cashReceived ??
          order.payments.fold<double>(0.0, (s, pay) => s + pay.amount);
      if (received - order.total > 0.001) {
        p.row('Received', formatAmount(received));
        p.row('Change', formatAmount(received - order.total));
      }
    }

    if (footer != null) {
      p.feed().align(EscPosAlign.center).line(footer!);
    }
    p.feed(2);
    // Kick the drawer before the cut on a cash sale, so the till opens as the
    // receipt prints rather than needing a separate command.
    if (openDrawer) p.openDrawer();
    return (p..cut()).build();
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
