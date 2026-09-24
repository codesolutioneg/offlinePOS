import 'dart:typed_data';

import '../../../core/printing/escpos.dart';
import '../../../domain/order.dart';
import '../restaurant_analytics.dart';
import 'flash_report_data.dart';
import 'flash_sales_summary_math.dart';
import 'flash_type_dialog.dart';

/// Dishflow thermal layout family for Flash reports.
enum FlashThermalKind {
  /// Flash Collector / Today's Flash / Payment Method Flash.
  control,

  /// Flash Summary.
  summary,

  /// Delivery Flash.
  delivery,
}

FlashThermalKind flashThermalKindFor(FlashKind kind) => switch (kind) {
      FlashKind.summary => FlashThermalKind.summary,
      FlashKind.delivery => FlashThermalKind.delivery,
      FlashKind.collector ||
      FlashKind.today ||
      FlashKind.paymentMethod =>
        FlashThermalKind.control,
    };

/// One monospaced line on the 42-col Dishflow slip.
class FlashThermalLine {
  const FlashThermalLine(this.text, {this.bold = false});
  final String text;
  final bool bold;
}

/// Build Dishflow 1:1 Flash slip lines from offline [Order]s, then ESC/POS bytes.
class FlashThermalEscPos {
  FlashThermalEscPos._();

  static const int W = 42;

  static String money(num v) {
    final n = v.toDouble();
    final neg = n < 0;
    final a = n.abs();
    final whole = a.floor();
    final frac = ((a - whole) * 100).round().clamp(0, 99);
    final w = _group(whole);
    final f = frac.toString().padLeft(2, '0');
    return '${neg ? '-' : ''}$w.$f';
  }

  static String _group(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  static String intFmt(num v) => _group(v.round());

  static String pct(num v) => v.toStringAsFixed(1);

  static String padR(String s, int w) =>
      s.length >= w ? s.substring(0, w) : s + ' ' * (w - s.length);

  static String padL(String s, int w) =>
      s.length >= w ? s.substring(s.length - w) : ' ' * (w - s.length) + s;

  static String ctr(String s) {
    if (s.length >= W) return s.substring(0, W);
    final l = (W - s.length) ~/ 2;
    return ' ' * l + s + ' ' * (W - s.length - l);
  }

  static String kv(String k, String v) {
    final room = W - v.length;
    if (room <= 0) return v.length > W ? v.substring(v.length - W) : v;
    return padR(k, room) + v;
  }

  static String row4(String c1, String c2, String c3, String c4,
          {int w1 = 14, int w2 = 8, int w3 = 10, int w4 = 10}) =>
      padR(c1, w1) + padL(c2, w2) + padL(c3, w3) + padL(c4, w4);

  static String row3(String c1, String c2, String c3,
          {int w1 = 22, int w2 = 8, int w3 = 12}) =>
      padR(c1, w1) + padL(c2, w2) + padL(c3, w3);

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _dateDmY(DateTime d) =>
      '${_two(d.day)}/${_two(d.month)}/${_two(d.year % 100)}';

  static String _dateMdY(DateTime d) =>
      '${_two(d.month)}/${_two(d.day)}/${_two(d.year % 100)}';

  static String _timeAmPm(DateTime d) {
    final h24 = d.hour;
    final h = h24 % 12 == 0 ? 12 : h24 % 12;
    final am = h24 < 12 ? 'AM' : 'PM';
    return '${_two(h)}:${_two(d.minute)} $am';
  }

  static String _ts(DateTime d, {required bool mdY}) {
    final date = mdY ? _dateMdY(d) : _dateDmY(d);
    return '$date ${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';
  }

  /// Public: lines for screen preview + print.
  static List<FlashThermalLine> lines({
    required FlashReportData data,
    required FlashThermalKind kind,
    required String shopName,
    String Function(int? categoryId)? categoryNameOf,
    bool Function(String paymentLabel)? isCashPayment,
  }) {
    final cashOf = isCashPayment ?? _defaultIsCash;
    final catOf = categoryNameOf ?? (_) => 'Other';
    return switch (kind) {
      FlashThermalKind.control =>
        _control(data, shopName, catOf, cashOf),
      FlashThermalKind.summary =>
        _summary(data, shopName, cashOf),
      FlashThermalKind.delivery =>
        _delivery(data, shopName, catOf, cashOf),
    };
  }

  static Uint8List build({
    required FlashReportData data,
    required FlashThermalKind kind,
    required String shopName,
    String Function(int? categoryId)? categoryNameOf,
    bool Function(String paymentLabel)? isCashPayment,
    int columns = W,
  }) {
    final built = lines(
      data: data,
      kind: kind,
      shopName: shopName,
      categoryNameOf: categoryNameOf,
      isCashPayment: isCashPayment,
    );
    final p = EscPos(columns: columns)..reset();
    for (final line in built) {
      if (line.bold) p.bold(true);
      p.line(line.text);
      if (line.bold) p.bold(false);
    }
    return (p..feed(3)..cut()).build();
  }

  static bool _defaultIsCash(String label) {
    final s = label.toLowerCase();
    return s.contains('cash') || s == 'نقدي' || s == 'كاش';
  }

  static int _ordersCountFor(List<Order> orders, String paymentLabel) {
    final want = paymentLabel.trim().toLowerCase();
    var n = 0;
    for (final o in orders) {
      if (o.payments.isEmpty) {
        if (want == 'cash') n++;
      } else if (o.payments
          .any((p) => (p.label ?? 'Cash').trim().toLowerCase() == want)) {
        n++;
      }
    }
    return n;
  }

  static String _firstPayment(Order o) {
    if (o.payments.isEmpty) return 'Cash';
    final l = (o.payments.first.label ?? '').trim();
    return l.isEmpty ? 'Cash' : l;
  }

  // ── Control (Collector / Today / Payment Method) ───────────────────────

  static List<FlashThermalLine> _control(
    FlashReportData data,
    String shopName,
    String Function(int? categoryId) catOf,
    bool Function(String) isCash,
  ) {
    final lines = <FlashThermalLine>[];
    void add(String t, {bool bold = false}) =>
        lines.add(FlashThermalLine(t, bold: bold));

    final orders = data.orders.where((o) => !o.isRefund).toList();
    final entries = data.byPaymentMethod.entries.toList();
    var cashTotal = 0.0, otherTotal = 0.0;
    for (final e in entries) {
      if (isCash(e.key)) {
        cashTotal += e.value;
      } else {
        otherTotal += e.value;
      }
    }
    final grand = cashTotal + otherTotal;

    final byGroup = <String, Map<String, num>>{};
    var checkDiscount = 0.0, orderDiscountTotal = 0.0;
    final checkDiscountRows = <MapEntry<String, double>>[];
    var customers = 0;
    var voids = data.orders.where((o) => o.isRefund).length;
    var itemDeletionsQty = 0;
    var itemDeletionsAmt = 0.0;
    DateTime? firstOrderAt, lastOrderAt;
    final orderRows = <Map<String, dynamic>>[];

    for (final o in data.orders.where((o) => o.isRefund)) {
      for (final l in o.lines) {
        itemDeletionsQty += l.quantity.round().abs();
        itemDeletionsAmt += l.total.abs();
      }
    }

    for (final o in orders) {
      customers += o.guestCount ?? 1;
      final dt = o.createdAt.toLocal();
      firstOrderAt =
          firstOrderAt == null || dt.isBefore(firstOrderAt) ? dt : firstOrderAt;
      lastOrderAt =
          lastOrderAt == null || dt.isAfter(lastOrderAt) ? dt : lastOrderAt;

      for (final l in o.lines) {
        final cat = catOf(l.categoryId).trim();
        final catKey = cat.isEmpty ? 'Other' : cat;
        final g = byGroup.putIfAbsent(catKey, () => {'qty': 0, 'amount': 0});
        g['qty'] = (g['qty'] ?? 0) + l.quantity;
        g['amount'] = (g['amount'] ?? 0) + l.total;
      }

      final oDisc = orderCheckDiscount(o);
      if (oDisc > 0.004) {
        orderDiscountTotal += oDisc;
        checkDiscount += oDisc;
        checkDiscountRows.add(MapEntry('Check Discount', oDisc));
      }

      orderRows.add({
        'id': o.displayNo,
        'time': dt,
        'pmt': _firstPayment(o),
        'amt': o.total,
        'tip': o.tip,
        'tbl': o.tableLabel ?? '',
      });
    }

    final groupRows = byGroup.entries.toList()
      ..sort((a, b) =>
          (b.value['amount'] ?? 0).compareTo(a.value['amount'] ?? 0));
    final groupTotalQty =
        groupRows.fold<num>(0, (a, e) => a + (e.value['qty'] ?? 0));
    final groupTotalAmt =
        groupRows.fold<num>(0, (a, e) => a + (e.value['amount'] ?? 0));
    final totalChecks = orders.length;
    final discTotal = orderDiscountTotal;
    final summary =
        FlashSalesSummaryMath(payments: grand, discounts: discTotal);
    final amountSales = summary.amountSales;
    final salesPlusDisc = summary.salesPlusDiscount;
    final netSales = summary.netBeforeTax;
    final taxes = summary.tax;
    final total = summary.total;
    final avgCheck = totalChecks == 0 ? 0.0 : netSales / totalChecks;
    final avgCheckGross =
        totalChecks == 0 ? 0.0 : salesPlusDisc / totalChecks;
    final avgCust = customers == 0 ? 0.0 : netSales / customers;
    final avgCustGross =
        customers == 0 ? 0.0 : salesPlusDisc / customers;

    final now = DateTime.now();
    final pFrom = firstOrderAt ?? now;
    final pTo = lastOrderAt ?? now;
    final hoursWorked = pTo.difference(pFrom).inMinutes / 60.0;

    final serverName = data.filterLabel?.trim().isNotEmpty == true
        ? data.filterLabel!.trim()
        : (data.title.contains('—')
            ? data.title.split('—').last.trim()
            : 'By Owner');
    final revenuesLabel = serverName == 'By Owner'
        ? 'By Owner all (${orders.length})'
        : '$serverName (${orders.length})';

    add('*' * W, bold: true);
    add(ctr(shopName), bold: true);
    add(ctr(data.title), bold: true);
    add('*' * W, bold: true);
    add('Server:        $serverName');
    add('Revenues:      $revenuesLabel');
    add(kv('Employee Meal', money(0)));
    add('');
    add('Date:          ${_dateDmY(now)}');
    add('Time:          ${_timeAmPm(now)}');
    add('LOGIN:         ${_ts(pFrom, mdY: false)}');
    add('LOGOUT:        ${_ts(pTo, mdY: false)}');
    add('');
    add(kv('HOURS WORKED:', hoursWorked.toStringAsFixed(2)));
    add('');
    add(kv('  ${padL(intFmt(customers), 4)} Guest', money(0)));
    add(kv('  ${padL(intFmt(voids), 4)} Void', money(0)));
    add('-' * W);
    add('');

    add(
        row4('Qty', 'Payment', 'Amount', 'Tip',
            w1: 5, w2: 17, w3: 10, w4: 10),
        bold: true);
    add('-' * W);
    for (final e in entries) {
      final n = _ordersCountFor(orders, e.key);
      add(row4(intFmt(n), e.key, money(e.value), money(0),
          w1: 5, w2: 17, w3: 10, w4: 10));
    }
    add(row4('', 'Cash Back', money(0), money(0),
        w1: 5, w2: 17, w3: 10, w4: 10));
    add(row4('', 'Cash Due', money(0), money(0),
        w1: 5, w2: 17, w3: 10, w4: 10));
    add('-' * W);
    add('');

    add(kv('Cash Receipts', money(cashTotal)), bold: true);
    add(kv('  Auto Gratuities', money(0)));
    add(kv('  Add Gratuities', money(0)));
    add(kv('  Cred Adj', money(0)));
    add(kv('  Money Drops', money(0)));
    add(kv('  Employee Paid Out', money(0)));
    add(kv('  Hash Total', money(0)));
    add(kv('  Cash Total', money(cashTotal)), bold: true);
    add('');
    add(kv('Revenues', money(grand)), bold: true);
    add(kv('  Auto Gratuities', money(0)));
    add(kv('  Add Gratuities', money(0)));
    add(kv('  Cred Adj', money(0)));
    add(kv('  Money Drops', money(0)));
    add(kv('  Employee Paid Out', money(0)));
    add(kv('  Hash Total', money(0)));
    add(kv('  Cash Total', money(grand)), bold: true);
    add('');

    add(ctr('SALES SUMMARY'), bold: true);
    add('');
    add(kv('Amount Sales', money(amountSales)));
    add(kv('TAX (14%)', money(taxes)));
    if (discTotal > 0) add(kv('DISCOUNTS', '-${money(discTotal)}'));
    add(kv('TOTAL', money(total)), bold: true);
    add('');

    add(ctr('CHECK DISCOUNTS'), bold: true);
    add('');
    add(row3('Discount Type', 'QTY', 'TOTAL'), bold: true);
    add('-' * W);
    if (checkDiscountRows.isEmpty) {
      add(row3('-', '0', money(0)));
    } else {
      final m = <String, Map<String, num>>{};
      for (final r in checkDiscountRows) {
        final g = m.putIfAbsent(r.key, () => {'qty': 0, 'amount': 0});
        g['qty'] = (g['qty'] ?? 0) + 1;
        g['amount'] = (g['amount'] ?? 0) + r.value;
      }
      for (final e in m.entries) {
        add(row3(
            e.key, intFmt(e.value['qty'] ?? 0), money(e.value['amount'] ?? 0)));
      }
    }
    add('-' * W);
    add(row3('TOTAL', intFmt(checkDiscountRows.length), money(checkDiscount)),
        bold: true);
    add('');

    add(ctr('COUPONS'), bold: true);
    add('');
    add(row3('Discount Type', 'QTY', 'TOTAL'), bold: true);
    add('-' * W);
    add(row3('-', '0', money(0)));
    add('-' * W);
    add(row3('TOTAL', '0', money(0)), bold: true);
    add('');

    add(ctr('STATISTICAL INFORMATION'), bold: true);
    add(ctr('(Voids, Empl Meals Excluded)'));
    add('');
    add(kv('CHECKS:', intFmt(totalChecks)));
    add(kv('AVG CHECK:', money(avgCheck)));
    add(kv('AVG CHECK (GROSS):', money(avgCheckGross)));
    add(kv('CUSTOMERS:', intFmt(customers)));
    add(kv('AVG CUST:', money(avgCust)));
    add(kv('AVG CUST (GROSS):', money(avgCustGross)));
    add(kv('OPEN CHECKS:', '0'));
    add(kv('ITEM DELETIONS:', intFmt(itemDeletionsQty)));
    add(kv('OPEN CHECK TOTAL:', money(0)));
    add(kv('OPEN CHECK CUST:', '0'));
    add(kv('SALES+OPEN TOTAL:', money(total)));
    add('');

    add(ctr('SALES BREAK DOWN'), bold: true);
    add(ctr('(Taxes not Included)'));
    add('');
    add(
        row4('Grp Type', 'QTY', 'TOTAL', 'PCT',
            w1: 14, w2: 6, w3: 12, w4: 8),
        bold: true);
    add('-' * W);
    for (final e in groupRows) {
      final amt = (e.value['amount'] ?? 0).toDouble();
      final p = groupTotalAmt == 0 ? 0.0 : (amt / groupTotalAmt) * 100.0;
      add(row4(e.key, intFmt(e.value['qty'] ?? 0), money(amt), pct(p),
          w1: 14, w2: 6, w3: 12, w4: 8));
    }
    if (groupRows.isEmpty) {
      add(row4('-', '0', money(0), '0.0', w1: 14, w2: 6, w3: 12, w4: 8));
    }
    add('-' * W);
    add(
        row4('Total :', intFmt(groupTotalQty), money(groupTotalAmt), '100.0',
            w1: 14, w2: 6, w3: 12, w4: 8),
        bold: true);
    add('');

    add(ctr('Item Deletions'), bold: true);
    add('');
    add(row3('', 'QTY', 'TOTAL'), bold: true);
    add('-' * W);
    if (itemDeletionsQty == 0) {
      add(row3('-', '0', money(0)));
    } else {
      add(row3(
          'Deleted Items', intFmt(itemDeletionsQty), money(itemDeletionsAmt)));
    }
    add('-' * W);
    add(row3('Total :', intFmt(itemDeletionsQty), money(itemDeletionsAmt)),
        bold: true);
    add('');

    add(ctr('DETAILED ORDER LISTING'), bold: true);
    add('');
    add(
        row4('Ord# Time', 'Pmt', 'Amt', 'Tip Tbl',
            w1: 14, w2: 8, w3: 10, w4: 10),
        bold: true);
    add('-' * W);
    for (final r in orderRows) {
      final id = '${r['id']}';
      final dt = r['time'] as DateTime?;
      final tStr = dt == null
          ? ''
          : '${_two(dt.hour)}:${_two(dt.minute)}';
      // Full sequential number (same as kitchen / receipt) — never clip the
      // tail of a legacy DDMM-SEQ-TAG into junk like "2-D50".
      final left = '$id $tStr';
      final pmt = '${r['pmt']}';
      final pmtShort = pmt.length > 8 ? pmt.substring(0, 8) : pmt;
      final tipTbl =
          '${money(r['tip'] as double)} ${(r['tbl'] as String).padLeft(2)}';
      add(row4(left, pmtShort, money(r['amt'] as double), tipTbl,
          w1: 14, w2: 8, w3: 10, w4: 10));
    }
    if (orderRows.isEmpty) add('  (no orders)');
    add('');
    add('*' * W, bold: true);
    add(ctr('-- End of Report --'), bold: true);
    add('*' * W, bold: true);

    return lines;
  }

  // ── Summary ────────────────────────────────────────────────────────────

  static List<FlashThermalLine> _summary(
    FlashReportData data,
    String shopName,
    bool Function(String) isCash,
  ) {
    final lines = <FlashThermalLine>[];
    void add(String t, {bool bold = false}) =>
        lines.add(FlashThermalLine(t, bold: bold));

    final orders = data.orders.where((o) => !o.isRefund).toList();
    final entries = data.byPaymentMethod.entries.toList();
    var cashTotal = 0.0, otherTotal = 0.0;
    for (final e in entries) {
      if (isCash(e.key)) {
        cashTotal += e.value;
      } else {
        otherTotal += e.value;
      }
    }
    final grand = cashTotal + otherTotal;

    var customersE = 0;
    var lineDiscountE = 0.0, checkDiscountE = 0.0, groupItemCountE = 0.0;
    for (final sale in orders) {
      customersE += sale.guestCount ?? 1;
      checkDiscountE += orderCheckDiscount(sale);
      if (sale.lines.isEmpty) groupItemCountE += 1;
      for (final item in sale.lines) {
        final qty = item.quantity;
        groupItemCountE += qty <= 0 ? 1 : qty;
        lineDiscountE += item.gross * item.discountPercent / 100;
      }
    }
    final totalChecksE = orders.length;
    final gTotalQtyE =
        groupItemCountE > 0 ? groupItemCountE : totalChecksE.toDouble();
    final totalDiscE = lineDiscountE + checkDiscountE;
    final flashSummaryE =
        FlashSalesSummaryMath(payments: grand, discounts: checkDiscountE);
    final amountSalesE = flashSummaryE.amountSales;
    final taxDueE = flashSummaryE.tax;
    final salesExTaxE = flashSummaryE.netBeforeTax;
    final flashTotalE = flashSummaryE.total;
    final flashDiscE = checkDiscountE;
    final paymentTypesTotalE = flashSummaryE.total;
    final groupCreditAlignedE = paymentTypesTotalE;

    final now = DateTime.now();
    DateTime? first, last;
    for (final o in orders) {
      final d = o.createdAt.toLocal();
      first = first == null || d.isBefore(first) ? d : first;
      last = last == null || d.isAfter(last) ? d : last;
    }
    final pFrom = first ?? now;
    final pTo = last ?? now;
    final sessionId =
        '${pFrom.year}${_two(pFrom.month)}${_two(pFrom.day)}';

    String row4e(String c1, String c2, String c3, String c4) =>
        padR(c1, 20) + padL(c2, 6) + padL(c3, 8) + padL(c4, 8);
    String row3e(String c1, String c2, String c3) =>
        padR(c1, 22) + padL(c2, 8) + padL(c3, 12);
    String kve(String k, String v) => padR(k, W - v.length) + v;
    String kvSe(String k, String sign, String v) {
      final vv = sign + v;
      return padR(k, W - vv.length) + vv;
    }

    add('=' * W, bold: true);
    add(ctr(shopName), bold: true);
    add(ctr(data.title), bold: true);
    add('=' * W, bold: true);
    add('Date:          ${_dateMdY(now)}');
    add('Time:          ${_timeAmPm(now)}');
    add('Session #:     $sessionId  ${_ts(pFrom, mdY: true)}');
    add('Filter Settings:');
    add('  Session Number is $sessionId');
    add('  ${_ts(pTo, mdY: true)}');
    add('');

    add('-' * W);
    add(ctr('Payment Types'), bold: true);
    add('-' * W);
    add(row4e('Description', 'Number', 'Debit', 'Credit'), bold: true);
    for (final e in entries) {
      final n = _ordersCountFor(orders, e.key);
      final cash = isCash(e.key);
      add(row4e(
          e.key, intFmt(n), cash ? money(e.value) : '', cash ? '' : money(e.value)));
    }
    if (entries.isEmpty) add(row4e('-', '0', '', '0.00'));
    add('-' * W);
    add(
        row4e(
            'Total',
            intFmt(entries.fold<int>(
                0, (a, e) => a + _ordersCountFor(orders, e.key))),
            '',
            money(paymentTypesTotalE)),
        bold: true);
    add('(Advance Orders Paid by Credit Card: )');
    add('');

    add('-' * W);
    add(ctr('Group Types'), bold: true);
    add('-' * W);
    add(row3e('Description', 'Number', 'Credit'), bold: true);
    add(row3e(
        'Uncategorized', intFmt(gTotalQtyE), money(groupCreditAlignedE)));
    add('-' * W);
    add(row3e('Total', intFmt(gTotalQtyE), money(groupCreditAlignedE)),
        bold: true);
    add('');

    add('-' * W);
    add(ctr('Hash Dept'), bold: true);
    add('-' * W);
    add(row3e(
        'Total w/Hash', intFmt(gTotalQtyE), money(groupCreditAlignedE)));
    add('');

    add(
        kve('Report Totals:',
            '${money(paymentTypesTotalE)}   ${money(paymentTypesTotalE)}'),
        bold: true);
    add('');

    add('-' * W);
    add(ctr('SALES SUMMARY'), bold: true);
    add('-' * W);
    add(kve('Amount Sales:', money(amountSalesE)));
    add(kve('TAX (14%):', money(taxDueE)));
    if (flashDiscE > 0) add(kve('DISCOUNTS:', '-${money(flashDiscE)}'));
    add(kve('TOTAL:', money(flashTotalE)), bold: true);
    add('');

    add('-' * W);
    add(ctr('Cash Handling Detail'), bold: true);
    add('-' * W);
    add(kve('Gross Cash:', money(cashTotal)));
    add(kvSe('Less Tips:', '-', money(0)));
    add(kvSe('Cash Back:', '-', money(0)));
    add(kvSe('Credit Card Fees:', '+', money(0)));
    add(kvSe('Paid Ins:', '+', money(0)));
    add(kvSe('Paid Outs:', '-', money(0)));
    add(kve('Net Cash:', money(cashTotal)), bold: true);
    add(kvSe('Other forms of payment:', '+', money(otherTotal)));
    add(kve('Net Received:', money(grand)), bold: true);
    add('');

    add('-' * W);
    add(ctr('Discount Detail'), bold: true);
    add('-' * W);
    add(kve('Line item discounts:', '-${money(lineDiscountE)}'));
    add(kve('Check Discounts:', '-${money(checkDiscountE)}'));
    add(kve('Guest:', intFmt(customersE)));
    add('-' * W);
    add(kve('Total:', '-${money(totalDiscE)}'), bold: true);
    add('');

    add('=' * W, bold: true);
    add(ctr('Totals'), bold: true);
    add('=' * W, bold: true);
    add(
        padR('', 12) +
            padL('Open', 10) +
            padL('Total', 10) +
            padL('%Settled', 10),
        bold: true);
    add(padR('Sales', 12) +
        padL(money(salesExTaxE), 10) +
        padL(money(salesExTaxE), 10) +
        padL('100.00', 10));
    add(padR('Customers', 12) +
        padL('0', 10) +
        padL(intFmt(customersE), 10) +
        padL('100.00', 10));
    add(padR('Checks', 12) +
        padL('0', 10) +
        padL(intFmt(totalChecksE), 10) +
        padL('100.00', 10));
    add(kve('Total Sales + Tax:', money(flashTotalE + taxDueE)), bold: true);
    add('');

    add('=' * W, bold: true);
    add(ctr('-- End of Report --'), bold: true);
    add('=' * W, bold: true);

    return lines;
  }

  // ── Delivery ───────────────────────────────────────────────────────────

  static List<FlashThermalLine> _delivery(
    FlashReportData data,
    String shopName,
    String Function(int? categoryId) catOf,
    bool Function(String) isCash,
  ) {
    final lines = <FlashThermalLine>[];
    void add(String t, {bool bold = false}) =>
        lines.add(FlashThermalLine(t, bold: bold));

    final orders = data.orders.where((o) => !o.isRefund).toList();
    final entries = data.byPaymentMethod.entries.toList();
    var cashTotal = 0.0, otherTotal = 0.0;
    for (final e in entries) {
      if (isCash(e.key)) {
        cashTotal += e.value;
      } else {
        otherTotal += e.value;
      }
    }
    final grand = cashTotal + otherTotal;

    final byGroup = <String, Map<String, num>>{};
    var checkDiscount = 0.0, orderDiscountTotal = 0.0;
    final checkDiscountRows = <MapEntry<String, double>>[];
    var customers = 0;
    final voids = data.orders.where((o) => o.isRefund).length;
    const itemDeletionsQty = 0;
    DateTime? firstOrderAt, lastOrderAt;

    for (final o in orders) {
      customers += o.guestCount ?? 1;
      final dt = o.createdAt.toLocal();
      firstOrderAt =
          firstOrderAt == null || dt.isBefore(firstOrderAt) ? dt : firstOrderAt;
      lastOrderAt =
          lastOrderAt == null || dt.isAfter(lastOrderAt) ? dt : lastOrderAt;
      for (final l in o.lines) {
        final cat = catOf(l.categoryId).trim();
        final catKey = cat.isEmpty ? 'Other' : cat;
        final g = byGroup.putIfAbsent(catKey, () => {'qty': 0, 'amount': 0});
        g['qty'] = (g['qty'] ?? 0) + l.quantity;
        g['amount'] = (g['amount'] ?? 0) + l.total;
      }
      final oDisc = orderCheckDiscount(o);
      if (oDisc > 0.004) {
        orderDiscountTotal += oDisc;
        checkDiscount += oDisc;
        checkDiscountRows.add(MapEntry('Check Discount', oDisc));
      }
    }

    final groupRows = byGroup.entries.toList()
      ..sort((a, b) =>
          (b.value['amount'] ?? 0).compareTo(a.value['amount'] ?? 0));
    final groupTotalQty =
        groupRows.fold<num>(0, (a, e) => a + (e.value['qty'] ?? 0));
    final groupTotalAmt =
        groupRows.fold<num>(0, (a, e) => a + (e.value['amount'] ?? 0));
    final totalChecks = orders.length;
    final discTotal = orderDiscountTotal;
    final summary =
        FlashSalesSummaryMath(payments: grand, discounts: discTotal);
    final amountSales = summary.amountSales;
    final salesPlusDisc = summary.salesPlusDiscount;
    final netSales = summary.netBeforeTax;
    final taxes = summary.tax;
    final total = summary.total;
    final avgCheck = totalChecks == 0 ? 0.0 : netSales / totalChecks;
    final avgCheckGross =
        totalChecks == 0 ? 0.0 : salesPlusDisc / totalChecks;
    final avgCust = customers == 0 ? 0.0 : netSales / customers;
    final avgCustGross =
        customers == 0 ? 0.0 : salesPlusDisc / customers;

    final now = DateTime.now();
    final pFrom = firstOrderAt ?? now;
    final sessionLabel =
        '${pFrom.year}${_two(pFrom.month)}${_two(pFrom.day)}';
    final filterLabel = data.filterLabel?.trim().isNotEmpty == true
        ? data.filterLabel!.trim()
        : (data.title.contains('—')
            ? data.title.split('—').last.trim()
            : 'Delivery');

    String partialSep([int w = 14]) => ' ' * (W - w) + '-' * w;
    String rightTotal(num v) => padL(money(v), W);

    add('*' * W, bold: true);
    add(ctr('FLASH REPORT'), bold: true);
    add('*' * W, bold: true);
    add('');
    add('FILTER: $filterLabel');
    add('');
    add('Date:${' ' * 5}${_dateDmY(now)}');
    add('Time:${' ' * 5}${_timeAmPm(now)}');
    add('Session:${' ' * 2}$sessionLabel');
    add('');
    add(kv('${padL(intFmt(customers), 3)} Guest', money(0)));
    add(kv('${padL(intFmt(voids), 3)} Void', money(0)));
    add(partialSep(16));
    add(rightTotal(0), bold: true);
    add('-' * W);
    add('');

    add(row4('Qty', 'Payment', 'Amount', 'Tip',
        w1: 5, w2: 17, w3: 10, w4: 10), bold: true);
    add('-' * W);
    for (final e in entries) {
      final n = _ordersCountFor(orders, e.key);
      add(row4(intFmt(n), e.key, money(e.value), money(0),
          w1: 5, w2: 17, w3: 10, w4: 10));
    }
    add(row4('', 'Cash Back', money(0), money(0),
        w1: 5, w2: 17, w3: 10, w4: 10));
    add('-' * W);
    add(
        row4(
            '',
            'TOTAL',
            money(entries.fold<double>(0.0, (a, e) => a + e.value)),
            money(0),
            w1: 5,
            w2: 17,
            w3: 10,
            w4: 10),
        bold: true);
    add('');

    add(ctr('SALES SUMMARY'), bold: true);
    add('');
    add(kv('Amount Sales', money(amountSales)));
    add(kv('TAX (14%)', money(taxes)));
    if (discTotal > 0) add(kv('DISCOUNTS', '-${money(discTotal)}'));
    add(kv('TOTAL', money(total)), bold: true);
    add('');

    add(ctr('CHECK DISCOUNTS'), bold: true);
    add('');
    add(row3('Discount Type', 'QTY', 'TOTAL'), bold: true);
    add('-' * W);
    if (checkDiscountRows.isEmpty) {
      add(row3('-', '0', money(0)));
    } else {
      final m = <String, Map<String, num>>{};
      for (final r in checkDiscountRows) {
        final g = m.putIfAbsent(r.key, () => {'qty': 0, 'amount': 0});
        g['qty'] = (g['qty'] ?? 0) + 1;
        g['amount'] = (g['amount'] ?? 0) + r.value;
      }
      for (final e in m.entries) {
        add(row3(
            e.key, intFmt(e.value['qty'] ?? 0), money(e.value['amount'] ?? 0)));
      }
    }
    add('-' * W);
    add(row3('TOTAL', intFmt(checkDiscountRows.length), money(checkDiscount)),
        bold: true);
    add('');

    add(ctr('COUPONS'), bold: true);
    add('');
    add(row3('Discount Type', 'QTY', 'TOTAL'), bold: true);
    add('-' * W);
    add(row3('-', '0', money(0)));
    add('-' * W);
    add(row3('TOTAL', '0', money(0)), bold: true);
    add('');

    add(ctr('STATISTICAL INFORMATION'), bold: true);
    add(ctr('(Voids, Empl Meals Excluded)'));
    add('');
    add(kv('CHECKS:', intFmt(totalChecks)));
    add(kv('AVG CHECK:', money(avgCheck)));
    add(kv('AVG CHECK (GROSS):', money(avgCheckGross)));
    add(kv('CUSTOMERS:', intFmt(customers)));
    add(kv('AVG CUST:', money(avgCust)));
    add(kv('AVG CUST (GROSS):', money(avgCustGross)));
    add(kv('OPEN CHECKS:', '0'));
    add(kv('ITEM DELETIONS:', intFmt(itemDeletionsQty)));
    add(kv('OPEN CHECK COST:', money(0)));
    add(kv('OPEN CHECK TOTAL:', money(0)));
    add(kv('SALES+OPEN TOTAL:', money(total)));
    add('');

    add(ctr('SALES BREAK DOWN'), bold: true);
    add(ctr('(Taxes not included)'));
    add('');
    add(
        row4('Grp Type', 'QTY', 'TOTAL', 'PCT',
            w1: 14, w2: 6, w3: 12, w4: 8),
        bold: true);
    add('-' * W);
    for (final e in groupRows) {
      final amt = (e.value['amount'] ?? 0).toDouble();
      final p = groupTotalAmt == 0 ? 0.0 : (amt / groupTotalAmt) * 100.0;
      add(row4(e.key, intFmt(e.value['qty'] ?? 0), money(amt), pct(p),
          w1: 14, w2: 6, w3: 12, w4: 8));
    }
    if (groupRows.isEmpty) {
      add(row4('-', '0', money(0), '0.0', w1: 14, w2: 6, w3: 12, w4: 8));
    }
    add('-' * W);
    add(
        row4('TOTAL', intFmt(groupTotalQty), money(groupTotalAmt), '100.0',
            w1: 14, w2: 6, w3: 12, w4: 8),
        bold: true);
    add('');
    add('*' * W, bold: true);

    return lines;
  }
}
