import 'flash_kind.dart';
import 'flash_report_data.dart';

class FlashSlipLine {
  const FlashSlipLine(this.text, {this.bold = false});
  final String text;
  final bool bold;
}

String _m(double v) => v.toStringAsFixed(2);
String _two(int n) => n.toString().padLeft(2, '0');
String _pad(String left, String right, [int w = 42]) {
  final space = w - left.length - right.length;
  if (space <= 0) return '$left $right';
  return '$left${' ' * space}$right';
}

bool _isCash(String label) {
  final s = label.toLowerCase();
  return s.contains('cash') || s == 'نقدي' || s == 'كاش';
}

/// Build a Dishflow-style monospace slip for every Flash kind.
List<FlashSlipLine> buildFlashSlip({
  required FlashReportData data,
  required FlashKind kind,
  required String shopName,
}) {
  return switch (kind) {
    FlashKind.summary => _summary(data, shopName),
    FlashKind.delivery => _delivery(data, shopName),
    FlashKind.collector ||
    FlashKind.today ||
    FlashKind.paymentMethod =>
      _control(data, shopName),
  };
}

List<FlashSlipLine> _summary(FlashReportData data, String shopName) {
  final lines = <FlashSlipLine>[];
  void add(String t, {bool bold = false}) =>
      lines.add(FlashSlipLine(t, bold: bold));

  var payments = 0.0;
  for (final e in data.byPaymentMethod.entries) {
    payments += e.value;
  }
  final math = FlashSalesSummaryMath(
    payments: payments,
    discounts: data.discountTotal,
  );

  add(shopName.toUpperCase(), bold: true);
  add(data.title, bold: true);
  add(data.periodLabel);
  if (data.filterLabel != null && data.filterLabel!.isNotEmpty) {
    add('Filter: ${data.filterLabel}');
  }
  add('-' * 42);
  add(_pad('ORDERS', '${data.ordersCount}'));
  add(_pad('AMOUNT SALES', _m(math.amountSales)), bold: true);
  add(_pad('DISCOUNTS', _m(math.discounts)));
  add(_pad('TAX (14%)', _m(math.tax)));
  add(_pad('TOTAL', _m(math.total)), bold: true);
  add('-' * 42);
  add('PAYMENTS', bold: true);
  for (final e in data.byPaymentMethod.entries) {
    add(_pad(e.key, _m(e.value)));
  }
  if (data.byOrderType.isNotEmpty) {
    add('-' * 42);
    add('BY TYPE', bold: true);
    for (final e in data.byOrderType.entries) {
      add(_pad(e.key, _m(e.value)));
    }
  }
  if (data.byCashier.isNotEmpty) {
    add('-' * 42);
    add('BY CASHIER', bold: true);
    for (final e in data.byCashier.entries) {
      add(_pad(e.key, _m(e.value)));
    }
  }
  add('-' * 42);
  add(_ts(DateTime.now()));
  return lines;
}

List<FlashSlipLine> _delivery(FlashReportData data, String shopName) {
  final lines = <FlashSlipLine>[];
  void add(String t, {bool bold = false}) =>
      lines.add(FlashSlipLine(t, bold: bold));

  add(shopName.toUpperCase(), bold: true);
  add('DELIVERY FLASH', bold: true);
  add(data.periodLabel);
  if (data.filterLabel != null) add('Filter: ${data.filterLabel}');
  add('-' * 42);
  add(_pad('ORDERS', '${data.ordersCount}'));
  add(_pad('NET SALES', _m(data.netSales)));
  add(_pad('TAX', _m(data.taxTotal)));
  add(_pad('DELIVERY FEES', _m(data.deliveryTotal)));
  add(_pad('TOTAL', _m(data.grossTotal)), bold: true);
  add('-' * 42);
  add('PAYMENTS', bold: true);
  for (final e in data.byPaymentMethod.entries) {
    add(_pad(e.key, _m(e.value)));
  }

  final byDriver = <String, ({int n, double total})>{};
  for (final o in data.orders) {
    final name = (o.driverName ?? '').trim().isEmpty
        ? 'No driver'
        : o.driverName!.trim();
    final was = byDriver[name];
    byDriver[name] =
        (n: (was?.n ?? 0) + 1, total: (was?.total ?? 0) + o.total);
  }
  if (byDriver.isNotEmpty) {
    add('-' * 42);
    add('BY DRIVER', bold: true);
    final rows = byDriver.entries.toList()
      ..sort((a, b) => b.value.total.compareTo(a.value.total));
    for (final e in rows) {
      add(_pad('${e.key} (${e.value.n})', _m(e.value.total)));
    }
  }

  add('-' * 42);
  add('ORDERS', bold: true);
  final sorted = [...data.orders]
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  for (final o in sorted) {
    final t = o.createdAt.toLocal();
    add(
      '${o.displayNo} ${_two(t.hour)}:${_two(t.minute)}  ${_m(o.total)}',
    );
    if ((o.driverName ?? '').trim().isNotEmpty) {
      add('  ${o.driverName}');
    }
  }
  add('-' * 42);
  add(_ts(DateTime.now()));
  return lines;
}

List<FlashSlipLine> _control(FlashReportData data, String shopName) {
  final lines = <FlashSlipLine>[];
  void add(String t, {bool bold = false}) =>
      lines.add(FlashSlipLine(t, bold: bold));

  var cashTotal = 0.0, otherTotal = 0.0;
  for (final e in data.byPaymentMethod.entries) {
    if (_isCash(e.key)) {
      cashTotal += e.value;
    } else {
      otherTotal += e.value;
    }
  }
  final grand = cashTotal + otherTotal;

  DateTime? firstAt, lastAt;
  var customers = 0;
  final byItem = <String, ({double qty, double net})>{};
  for (final o in data.orders) {
    customers += o.guestCount ?? 1;
    final dt = o.createdAt.toLocal();
    firstAt = firstAt == null || dt.isBefore(firstAt) ? dt : firstAt;
    lastAt = lastAt == null || dt.isAfter(lastAt) ? dt : lastAt;
    for (final l in o.lines) {
      final name = l.name.trim().isEmpty ? '—' : l.name.trim();
      final was = byItem[name];
      byItem[name] = (
        qty: (was?.qty ?? 0) + l.quantity,
        net: (was?.net ?? 0) + l.total,
      );
    }
  }

  add(shopName.toUpperCase(), bold: true);
  add(data.title, bold: true);
  add(data.periodLabel);
  if (data.filterLabel != null && data.filterLabel!.isNotEmpty) {
    add('Filter: ${data.filterLabel}');
  }
  add('-' * 42);
  add(_pad('ORDERS', '${data.ordersCount}'));
  add(_pad('CUSTOMERS', '$customers'));
  add(_pad('NET SALES', _m(data.netSales)));
  add(_pad('DISCOUNTS', _m(data.discountTotal)));
  add(_pad('TAX (VAT)', _m(data.taxTotal)));
  add(_pad('DELIVERY', _m(data.deliveryTotal)));
  if (data.tipTotal.abs() > 0.004) {
    add(_pad('TIPS', _m(data.tipTotal)));
  }
  add(_pad('TOTAL', _m(data.grossTotal)), bold: true);
  add('-' * 42);
  add('CASH / OTHER', bold: true);
  add(_pad('Cash', _m(cashTotal)));
  add(_pad('Other', _m(otherTotal)));
  add(_pad('Grand', _m(grand)), bold: true);
  add('-' * 42);
  add('PAYMENTS', bold: true);
  for (final e in data.byPaymentMethod.entries) {
    add(_pad(e.key, _m(e.value)));
  }
  if (data.byOrderType.length > 1) {
    add('-' * 42);
    add('BY TYPE', bold: true);
    for (final e in data.byOrderType.entries) {
      add(_pad(e.key, _m(e.value)));
    }
  }
  if (data.byCashier.length > 1) {
    add('-' * 42);
    add('BY CASHIER', bold: true);
    for (final e in data.byCashier.entries) {
      add(_pad(e.key, _m(e.value)));
    }
  }
  if (data.byDevice.length > 1) {
    add('-' * 42);
    add('BY TILL', bold: true);
    for (final e in data.byDevice.entries) {
      add(_pad(e.key, _m(e.value)));
    }
  }
  if (byItem.isNotEmpty) {
    add('-' * 42);
    add('ITEMS', bold: true);
    final items = byItem.entries.toList()
      ..sort((a, b) => b.value.net.compareTo(a.value.net));
    for (final e in items.take(40)) {
      final qty = e.value.qty == e.value.qty.roundToDouble()
          ? e.value.qty.toStringAsFixed(0)
          : e.value.qty.toStringAsFixed(1);
      add(_pad('$qty x ${e.key}', _m(e.value.net)));
    }
  }
  add('-' * 42);
  add('CHECKS', bold: true);
  final sorted = [...data.orders]
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  for (final o in sorted) {
    final t = o.createdAt.toLocal();
    final pay = o.payments.isEmpty
        ? 'Cash'
        : (o.payments.first.label ?? 'Cash');
    add(
      '${o.displayNo} ${_two(t.hour)}:${_two(t.minute)} $pay ${_m(o.total)}',
    );
  }
  if (firstAt != null && lastAt != null) {
    add('-' * 42);
    add('First: ${_ts(firstAt)}');
    add('Last:  ${_ts(lastAt)}');
  }
  add('-' * 42);
  add(_ts(DateTime.now()));
  return lines;
}

String _ts(DateTime d) {
  final l = d.toLocal();
  return '${_two(l.day)}/${_two(l.month)}/${l.year} '
      '${_two(l.hour)}:${_two(l.minute)}:${_two(l.second)}';
}
