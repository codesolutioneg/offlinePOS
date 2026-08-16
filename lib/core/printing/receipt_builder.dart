import 'dart:typed_data';

import '../../domain/order.dart';
import 'escpos.dart';

/// One payment that does not settle the whole bill: an even-split share, any part
/// payment, or a guest/item check taken off a table that stays open.
///
/// Carries what the payment covered and what the bill still owes, which is the one
/// thing no other slip can say: the sale receipt is not printed until the tab is
/// settled, and the pre-bill is printed before the money moves.
class PartialPayment {
  const PartialPayment({
    required this.order,
    required this.paidNow,
    required this.stillOwed,
    this.title,
    this.tenders = const [],
    this.covered = const [],
    this.cashReceived,
  });

  /// The bill the payment was taken against, for its table, number and cashier.
  final Order order;

  /// What was settled by this payment, tip included.
  final double paidNow;

  /// What the bill still owes after it, so the next guest (or the waiter) knows
  /// what is left to collect.
  final double stillOwed;

  /// What this payment is called on paper: a guest, a share, a check.
  final String? title;

  /// The tenders that made up this payment, so a share paid part cash part card
  /// reads on the slip the way the sale receipt would show it.
  final List<OrderPayment> tenders;

  /// The lines this payment covered, when it paid for items rather than a share of
  /// the money. Empty for an even split: there is nothing itemised to show.
  final List<OrderLine> covered;

  /// Cash handed over, when it was more than the amount settled, so the slip can
  /// print the change the way a sale receipt does.
  final double? cashReceived;
}

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
    this.showTotals = true,
    this.dividerStyle = 'line',
    this.openDrawer = false,
    this.logo,
    this.paymentLabels = const {},
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

  /// Print the money at the foot: the breakdown, the tax lines, the total and what
  /// was tendered. Off turns the slip into a packing list, which is the only thing a
  /// copy for the pass should be: a runner must not be able to hand it over as a
  /// second priced receipt.
  final bool showTotals;

  /// Which character separator lines are drawn with, as stored by the receipt
  /// designer. Anything unrecognised falls back to a dashed rule.
  final String dividerStyle;

  static const _dividerChars = {'line': '-', 'equals': '=', 'dots': '.', 'stars': '*'};

  /// Kick the cash drawer open at the end, for a cash sale.
  final bool openDrawer;

  /// What each payment method is called on paper, by method id, when the shop wants
  /// something other than the name that came down from the server. Print-time only:
  /// the tender itself keeps the id and the label it was rung with.
  final Map<int, String> paymentLabels;

  /// The printer command that puts the shop's mark above the name, or null for the
  /// text-only slip this always printed. Composed by the caller (see PrinterLogo)
  /// because which of the two logo routes a shop is on depends on its hardware, and
  /// this class stays free of settings.
  final Uint8List? logo;

  Uint8List build(Order order, {bool reprint = false}) =>
      _slip(order, reprint: reprint);

  /// The check handed to a table before it pays: the sale layout without anything
  /// that implies money changed hands. No tender or change section, no drawer kick,
  /// and it says on the paper that it is not a tax receipt, because a waiter carries
  /// this to the table and the customer must not mistake it for the real slip.
  ///
  /// Takes the order as-is and reads nothing but its lines and totals, so a bill can
  /// be printed as often as the table asks for it.
  Uint8List buildBill(Order order) => _slip(order, bill: true);

  Uint8List _slip(Order order, {bool reprint = false, bool bill = false}) {
    final p = EscPos(columns: columns)..reset();
    final divider = _dividerChars[dividerStyle] ?? '-';

    p.align(EscPosAlign.center);
    // Above the name, where a customer looks first, and while the printer is still
    // centred so the mark sits in the middle of the roll.
    if (logo != null) p.command(logo!).feed();
    p.size(doubleWidth: true, doubleHeight: true)
      ..bold(true)
      ..line(shopName)
      ..bold(false)
      ..size();
    if (header != null && header!.isNotEmpty) p.centred(header!);
    if (taxId != null) p.line(taxId!);
    // A reprint is marked so a duplicate slip cannot be passed off as a second sale;
    // a refund is marked so a returned sale is never mistaken for a new one.
    if (order.isRefund) p.centred('*** REFUND ***');
    if (reprint) p.centred('*** REPRINT ***');
    // A bill is titled and disclaimed at the top, where a customer reads first.
    if (bill) {
      p.size(doubleHeight: true).centred('*** BILL ***').size();
      p.centred('NOT A TAX RECEIPT');
    }
    // A sale corrected after it was first tendered says so, so a customer holding
    // the slip from before the correction can see which of the two stands.
    if (order.amended) p.centred('*** AMENDED ***');
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
      if (showNumber) '#${order.displayNo}',
    ].join('  ');
    if (stamped.isNotEmpty) p.line(stamped);
    if (showCashier) p.line('Cashier: ${order.cashierId}');
    if (order.customerName != null) p.line('Customer: ${order.customerName}');
    // A delivery slip goes out with the bag, so it has to be enough for the driver
    // to find the door and ring ahead. Name alone is a slip nobody can deliver.
    // Everything here is captured on the till, and prints with the line down.
    if (order.type == OrderType.delivery) {
      if (order.customerPhone != null && order.customerPhone!.isNotEmpty) {
        p.line('Phone: ${order.customerPhone}');
      }
      if (order.customerAddress != null && order.customerAddress!.isNotEmpty) {
        // Wrapped here rather than left to the printer: half an address is no
        // address, and a roll that wraps mid-word is hard to read at a door.
        for (final part in _wrap('Address: ${order.customerAddress}')) {
          p.line(part);
        }
      }
      // The aggregator's own reference is what the rider and the call centre quote,
      // so it belongs on the paper next to the channel that issued it.
      final channel = [
        if (order.deliveryChannel != null) order.deliveryChannel!,
        if (order.companyOrderNo != null) '#${order.companyOrderNo}',
      ].join(' ');
      if (channel.isNotEmpty) p.line('Channel: $channel');
      if (order.driverName != null) p.line('Driver: ${order.driverName}');
    }
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
    final hasBreakdown = showTotals &&
        (order.discountPercent > 0 ||
            order.serviceChargePercent > 0 ||
            order.deliveryCost > 0 ||
            order.tip > 0);
    if (hasBreakdown) {
      p.row('Subtotal', formatAmount(order.subtotal));
      if (order.discountPercent > 0) {
        final label = order.discountReason == null
            ? 'Discount ${_pct(order.discountPercent)}%'
            : 'Discount ${_pct(order.discountPercent)}% (${order.discountReason})';
        p.row(label, '-${formatAmount(order.subtotal * order.discountPercent / 100)}');
      }
      // After the discount, because that is what it is charged on, and on its own line:
      // a guest is entitled to see the service they are paying rather than find it
      // buried in the item prices.
      if (order.serviceChargePercent > 0) {
        p.row('Service ${_pct(order.serviceChargePercent)}%',
            formatAmount(order.serviceCharge));
      }
      if (order.deliveryCost > 0) p.row('Delivery', formatAmount(order.deliveryCost));
      if (order.tip > 0) p.row('Tip', formatAmount(order.tip));
    }
    // Tax is shown as included in the total (prices are tax-inclusive), so the
    // slip is a valid tax receipt without changing what the customer pays.
    final tax = order.taxTotal;
    if (showTax && showTotals && tax > 0.001) {
      p.row('Net', formatAmount(order.total - tax));
      p.row('Tax', formatAmount(tax));
    }
    if (showTotals) {
      p.size(doubleHeight: true).bold(true)
        ..row('TOTAL', formatAmount(order.total))
        ..bold(false)
        ..size();
    }

    // Tender breakdown and change. A split payment prints one line per tender.
    // Payments store the settled amount, so a cash overpayment prints the cash
    // received and the change owed from [cashReceived] rather than from the tender.
    if (showTotals && !bill && order.payments.isNotEmpty) {
      p.feed();
      if (showPayment) {
        for (final pay in order.payments) {
          p.row(paymentLabels[pay.methodId] ?? pay.label ?? 'Payment',
              formatAmount(pay.amount));
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

    // A part-paid tab (an even or per-guest split settled one share at a time) still
    // owes less than its total, so the bill states what is left rather than sending
    // the waiter back to collect the whole amount again. This is what is due, not a
    // tender breakdown, and a settled tab prints nothing here because there is
    // nothing left to collect.
    if (bill && order.amountPaid > 0.001 && order.balance > 0.001) {
      p.row('Already paid', '-${formatAmount(order.amountPaid)}');
      p.size(doubleHeight: true).bold(true)
        ..row('BALANCE DUE', formatAmount(order.balance))
        ..bold(false)
        ..size();
    }

    if (footer != null) {
      p.feed().align(EscPosAlign.center).line(footer!);
    }
    p.feed(2);
    // Kick the drawer before the cut on a cash sale, so the till opens as the
    // receipt prints rather than needing a separate command. A bill is not a sale,
    // so it never opens the till.
    if (openDrawer && !bill) p.openDrawer();
    return (p..cut()).build();
  }

  /// A record slip for removed items or a cancelled order, printed on the receipt
  /// printer so a void or cancel always leaves a paper trail at the till. This is
  /// not a kitchen ticket: it documents what was taken off and why, with the amount
  /// removed, for the drawer and the customer. [at] is the moment of removal (the
  /// caller's clock), [actor] who did it, [reason] why.
  Uint8List buildDeletion(
    Order order,
    List<OrderLine> lines, {
    required String title,
    required DateTime at,
    String? reason,
    String? actor,
  }) {
    final p = EscPos(columns: columns)..reset();
    final divider = _dividerChars[dividerStyle] ?? '-';

    p.align(EscPosAlign.center)
      ..bold(true)
      ..line(shopName)
      ..bold(false);
    p.size(doubleHeight: true).centred('*** $title ***').size();
    p.align(EscPosAlign.left).rule(divider);

    p.line('${_stamp(at)}  #${order.displayNo}');
    if (actor != null) p.line('Cashier: $actor');
    if (order.type == OrderType.dineIn && order.tableLabel != null) {
      p.line('Table ${order.tableLabel}');
    }
    p.rule(divider);

    var removed = 0.0;
    for (final l in lines) {
      p.row('${_qty(l.quantity)} x ${l.name}', formatAmount(l.total));
      removed += l.total;
    }
    p.rule(divider);
    // A whole-order discount and the bill's service charge both scale what the customer
    // would actually have paid for the removed lines, so the REMOVED figure nets them
    // off rather than printing the gross line sum. Both are itemised so the numbers
    // reconcile on the slip.
    if (order.discountPercent > 0 || order.serviceChargePercent > 0) {
      p.row('Subtotal', formatAmount(removed));
    }
    if (order.discountPercent > 0) {
      p.row('Order discount ${_pct(order.discountPercent)}%',
          '-${formatAmount(removed * order.discountPercent / 100)}');
    }
    if (order.serviceChargePercent > 0) {
      final serviced = removed * order.discountFactor;
      p.row('Service ${_pct(order.serviceChargePercent)}%',
          formatAmount(serviced * order.serviceChargePercent / 100));
    }
    p.size(doubleHeight: true).bold(true)
      ..row('REMOVED',
          formatAmount(removed * order.discountFactor * order.serviceChargeFactor))
      ..bold(false)
      ..size();
    if (reason != null && reason.isNotEmpty) p.feed().line('Reason: $reason');

    p.feed(2);
    // Never kick the drawer on a deletion slip: removing an item does not open the
    // till.
    return (p..cut()).build();
  }

  /// The detail slip for a payment that leaves the bill part paid: what this
  /// payment covered, how it was tendered, and what is still owed.
  ///
  /// Its own layout rather than the sale slip's, because the two say different
  /// things: a sale receipt closes a bill, this one documents a payment against a
  /// bill that stays open. It is marked as not a tax receipt for the same reason
  /// the pre-bill is: the tax receipt is the one that prints when the tab settles.
  /// [at] is the moment of payment (the caller's clock), [actor] who took it.
  Uint8List buildPartialPayment(
    PartialPayment payment, {
    required DateTime at,
    String? actor,
  }) {
    final order = payment.order;
    final p = EscPos(columns: columns)..reset();
    final divider = _dividerChars[dividerStyle] ?? '-';

    p.align(EscPosAlign.center)
      ..bold(true)
      ..line(shopName)
      ..bold(false);
    p.size(doubleHeight: true).centred('*** PAYMENT ***').size();
    p.centred('NOT A TAX RECEIPT');
    p.align(EscPosAlign.left).rule(divider);

    p.line('${_stamp(at)}  #${order.displayNo}');
    if (showTable && order.type == OrderType.dineIn && order.tableLabel != null) {
      p.line('Table ${order.tableLabel}');
    }
    if (showCashier && actor != null) p.line('Cashier: $actor');
    // Whose share this was, so a table settling guest by guest can tell the slips
    // apart on the spike at the end of the night.
    if (payment.title != null && payment.title!.isNotEmpty) {
      p.bold(true).line(payment.title!).bold(false);
    }

    // What the money bought, when it bought items. An even split buys a share of
    // everything, so there is nothing to itemise and the section is skipped.
    if (payment.covered.isNotEmpty) {
      p.rule(divider);
      for (final l in payment.covered) {
        p.row('${_qty(l.quantity)} x ${l.name}',
            showItemPrice ? formatAmount(l.total) : '');
      }
    }

    p.rule(divider);
    if (showPayment) {
      for (final t in payment.tenders) {
        p.row(paymentLabels[t.methodId] ?? t.label ?? 'Payment', formatAmount(t.amount));
      }
    }
    final received = payment.cashReceived;
    if (received != null && received - payment.paidNow > 0.001) {
      p.row('Received', formatAmount(received));
      p.row('Change', formatAmount(received - payment.paidNow));
    }
    p.size(doubleHeight: true).bold(true)
      ..row('PAID NOW', formatAmount(payment.paidNow))
      ..bold(false)
      ..size();

    // The point of the slip. Big, because the next guest reads this number and the
    // waiter collects it.
    p.rule(divider);
    p.size(doubleHeight: true).bold(true)
      ..row('STILL OWED', formatAmount(payment.stillOwed))
      ..bold(false)
      ..size();

    p.feed(2);
    // Cash taken as a part payment goes in the drawer like any other cash, so the
    // drawer opens on this slip too when the shop has it wired that way.
    if (openDrawer) p.openDrawer();
    return (p..cut()).build();
  }

  /// [text] broken onto lines that fit the roll, at spaces where there is one. A
  /// single word longer than the paper is left alone for the printer to deal with,
  /// which is better than cutting a street name in half.
  List<String> _wrap(String text) {
    final out = <String>[];
    var current = '';
    for (final word in text.split(' ')) {
      if (current.isEmpty) {
        current = word;
      } else if (current.length + 1 + word.length <= columns) {
        current = '$current $word';
      } else {
        out.add(current);
        current = word;
      }
    }
    if (current.isNotEmpty) out.add(current);
    return out;
  }

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
