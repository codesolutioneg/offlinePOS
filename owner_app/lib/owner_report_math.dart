import 'orders.dart';
import 'report_catalog.dart';
import 'sessions.dart';

class ReportTable {
  const ReportTable({required this.headers, required this.rows});
  final List<String> headers;
  final List<List<String>> rows;
}

String _m(double v) => v.toStringAsFixed(2);
String _q(double q) =>
    q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(2);

List<OwnerOrder> ordersForReport(List<OwnerOrder> completed, String key) {
  if (kRefundReportKeys.contains(key)) {
    return withoutFullyCancelled(completed);
  }
  if (key == 'rep-driver' || key == 'rep-driver-account') {
    return [
      for (final o in salesForReports(completed))
        if (o.orderType.toLowerCase().contains('deliver') ||
            (o.driverName ?? '').trim().isNotEmpty)
          o,
    ];
  }
  return salesForReports(completed);
}

ReportTable buildOwnerReport({
  required String key,
  required List<OwnerOrder> completed,
  required Map<int, double> costs,
  List<OwnerOrder> previous = const [],
  List<({String reason, double amount, DateTime at, String? category})>
      expenses = const [],
  List<OwnerSessionInfo> sessions = const [],
  required bool arabic,
}) {
  final orders = ordersForReport(completed, key);
  return switch (key) {
    'rep-session-summary' => _sessionSummary(orders, sessions, arabic),
    'rep-summary' => _summary(orders, arabic),
    'rep-session-detail' => _sessionDetail(orders, sessions, arabic),
    'rep-item-sales' || 'rep-top' || 'rep-group-sales' || 'rep-category' =>
      _itemSales(orders, costs, arabic, groupOnly: key == 'rep-group-sales'),
    'rep-detailed-discounts' || 'rep-discounts' => _discounts(orders, arabic),
    'rep-time' => _byHour(orders, arabic),
    'rep-expenses' => _expenses(expenses, arabic),
    'rep-refunds' || 'rep-activity' || 'rep-refunds-summary' =>
      _refunds(orders, arabic),
    'rep-driver' || 'rep-driver-account' => _drivers(orders, arabic),
    'rep-payment' => _payments(orders, arabic),
    'rep-tax' => _tax(orders, arabic),
    'rep-revenue-center' => _revenueCenter(orders, arabic),
    'rep-daily-sales' => _daily(orders, arabic),
    'rep-modifiers' => _modifiers(orders, arabic),
    'rep-period-compare' => _compare(
        salesForReports(completed), salesForReports(previous), arabic),
    _ => ReportTable(
        headers: [arabic ? 'ملاحظة' : 'Note'],
        rows: [
          [arabic ? 'تقرير غير مدعوم' : 'Unsupported report'],
        ],
      ),
  };
}

ReportTable _summary(List<OwnerOrder> orders, bool ar) {
  final net = orders.fold(0.0, (s, o) => s + o.subtotal);
  final total = orders.fold(0.0, (s, o) => s + o.total);
  final tax = orders.fold(0.0, (s, o) => s + o.taxTotal);
  final disc =
      orders.fold(0.0, (s, o) => s + o.checkDiscount + o.lineDiscount);
  final tip = orders.fold(0.0, (s, o) => s + o.tip);
  final delivery = orders.fold(0.0, (s, o) => s + o.deliveryCost);
  return ReportTable(
    headers: [ar ? 'البند' : 'Metric', ar ? 'القيمة' : 'Value'],
    rows: [
      [ar ? 'الطلبات' : 'Orders', '${orders.length}'],
      [ar ? 'صافي المبيعات' : 'Net sales', _m(net)],
      [ar ? 'الخصم' : 'Discount', _m(disc)],
      [ar ? 'الضريبة' : 'Tax', _m(tax)],
      [ar ? 'التوصيل' : 'Delivery', _m(delivery)],
      [ar ? 'البقشيش' : 'Tip', _m(tip)],
      [ar ? 'الإجمالي' : 'Total', _m(total)],
      [
        ar ? 'متوسط الفاتورة' : 'Average check',
        orders.isEmpty ? '0.00' : _m(total / orders.length),
      ],
    ],
  );
}

ReportTable _sessionSummary(
  List<OwnerOrder> orders,
  List<OwnerSessionInfo> sessions,
  bool ar,
) {
  final open = sessions.where((s) => s.isOpen).length;
  final closed = sessions.length - open;
  final base = _summary(orders, ar);
  return ReportTable(
    headers: base.headers,
    rows: [
      [ar ? 'جلسات مفتوحة' : 'Open sessions', '$open'],
      [ar ? 'جلسات مقفولة' : 'Closed sessions', '$closed'],
      [ar ? 'إجمالي الجلسات' : 'Total sessions', '${sessions.length}'],
      ...base.rows,
      if (sessions.isNotEmpty) ...[
        [ar ? '— حالة الجلسات —' : '— Session status —', ''],
        for (final s in sessions)
          [
            s.cashierId.isEmpty ? s.deviceId : s.cashierId,
            ar ? s.statusAr : s.statusEn,
          ],
      ],
    ],
  );
}

ReportTable _sessionDetail(
  List<OwnerOrder> orders,
  List<OwnerSessionInfo> sessions,
  bool ar,
) {
  final sorted = [...orders]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  final statusByDevice = <String, String>{
    for (final s in sessions)
      s.deviceId: ar ? s.statusAr : s.statusEn,
  };
  return ReportTable(
    headers: [
      ar ? 'رقم' : 'No',
      ar ? 'الوقت' : 'Time',
      ar ? 'النوع' : 'Type',
      ar ? 'الجلسة' : 'Session',
      ar ? 'الصافي' : 'Net',
      ar ? 'ضريبة' : 'Tax',
      ar ? 'الإجمالي' : 'Total',
      ar ? 'الدفع' : 'Pay',
    ],
    rows: [
      for (final o in sorted)
        () {
          final t = o.createdAt.toLocal();
          final pay = o.payments.isEmpty
              ? 'Cash'
              : o.payments.map((p) => p.label ?? 'Cash').join('+');
          final st = statusByDevice[o.deviceId] ?? '—';
          return [
            o.displayNo,
            '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
            o.orderType,
            st,
            _m(o.subtotal),
            _m(o.taxTotal),
            _m(o.total),
            pay,
          ];
        }(),
    ],
  );
}

ReportTable _itemSales(
  List<OwnerOrder> orders,
  Map<int, double> costs,
  bool ar, {
  bool groupOnly = false,
}) {
  final map = <String, ({double qty, double net, double cost})>{};
  for (final o in orders) {
    for (final l in o.lines) {
      final key = l.name.trim().isEmpty ? '—' : l.name.trim();
      final was = map[key];
      map[key] = (
        qty: (was?.qty ?? 0) + l.quantity,
        net: (was?.net ?? 0) + l.total,
        cost: (was?.cost ?? 0) + (costs[l.productId] ?? 0) * l.quantity,
      );
    }
  }
  final rows = map.entries.toList()
    ..sort((a, b) => b.value.net.compareTo(a.value.net));
  if (groupOnly) {
    // Without catalogue groups, roll items into one "Items" bucket + top names.
    final net = rows.fold(0.0, (s, e) => s + e.value.net);
    final qty = rows.fold(0.0, (s, e) => s + e.value.qty);
    final cost = rows.fold(0.0, (s, e) => s + e.value.cost);
    return ReportTable(
      headers: [
        ar ? 'المجموعة' : 'Group',
        ar ? 'الكمية' : 'Qty',
        ar ? 'المبيعات' : 'Sales',
        ar ? 'التكلفة' : 'Cost',
      ],
      rows: [
        [ar ? 'الأصناف' : 'Items', _q(qty), _m(net), _m(cost)],
        ...[
          for (final e in rows.take(20))
            ['  ${e.key}', _q(e.value.qty), _m(e.value.net), _m(e.value.cost)],
        ],
      ],
    );
  }
  return ReportTable(
    headers: [
      ar ? 'الصنف' : 'Item',
      ar ? 'الكمية' : 'Qty',
      ar ? 'المبيعات' : 'Sales',
      ar ? 'التكلفة' : 'Cost',
      ar ? 'التكلفة %' : 'Cost %',
    ],
    rows: [
      for (final e in rows)
        [
          e.key,
          _q(e.value.qty),
          _m(e.value.net),
          _m(e.value.cost),
          e.value.net == 0
              ? '0.0'
              : (e.value.cost / e.value.net * 100).toStringAsFixed(1),
        ],
    ],
  );
}

ReportTable _discounts(List<OwnerOrder> orders, bool ar) {
  final rows = <List<String>>[];
  for (final o in orders) {
    if (o.checkDiscount > 0.005) {
      rows.add([
        o.displayNo,
        ar ? 'فاتورة' : 'Check',
        o.discountReason ?? '${o.discountPercent}%',
        _m(o.checkDiscount),
      ]);
    }
    for (final l in o.lines) {
      if (l.discountPercent <= 0) continue;
      final raw = l.gross;
      rows.add([
        o.displayNo,
        l.name,
        '${l.discountPercent}%',
        _m(raw - l.total),
      ]);
    }
  }
  return ReportTable(
    headers: [
      ar ? 'طلب' : 'Order',
      ar ? 'البند' : 'Item',
      ar ? 'السبب' : 'Reason',
      ar ? 'الخصم' : 'Discount',
    ],
    rows: rows,
  );
}

ReportTable _byHour(List<OwnerOrder> orders, bool ar) {
  final buckets = List<({int n, double net})>.generate(
      24, (_) => (n: 0, net: 0.0));
  for (final o in orders) {
    final h = o.createdAt.toLocal().hour;
    final b = buckets[h];
    buckets[h] = (n: b.n + 1, net: b.net + o.total);
  }
  return ReportTable(
    headers: [
      ar ? 'الساعة' : 'Hour',
      ar ? 'الطلبات' : 'Orders',
      ar ? 'المبيعات' : 'Sales',
    ],
    rows: [
      for (var h = 0; h < 24; h++)
        if (buckets[h].n > 0)
          [
            h.toString().padLeft(2, '0'),
            '${buckets[h].n}',
            _m(buckets[h].net),
          ],
    ],
  );
}

ReportTable _expenses(
  List<({String reason, double amount, DateTime at, String? category})> rows,
  bool ar,
) {
  return ReportTable(
    headers: [
      ar ? 'الوقت' : 'When',
      ar ? 'الفئة' : 'Category',
      ar ? 'السبب' : 'Reason',
      ar ? 'المبلغ' : 'Amount',
    ],
    rows: [
      for (final e in rows)
        () {
          final t = e.at.toLocal();
          return [
            '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
            e.category ?? '—',
            e.reason.isEmpty ? '—' : e.reason,
            _m(e.amount),
          ];
        }(),
    ],
  );
}

ReportTable _refunds(List<OwnerOrder> orders, bool ar) {
  final refunds = [
    for (final o in orders)
      if (o.isRefund || o.total < 0) o,
  ];
  return ReportTable(
    headers: [
      ar ? 'رقم' : 'No',
      ar ? 'الوقت' : 'Time',
      ar ? 'الأصل' : 'Of',
      ar ? 'المبلغ' : 'Amount',
    ],
    rows: [
      for (final o in refunds)
        () {
          final t = o.createdAt.toLocal();
          return [
            o.displayNo,
            '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
            o.refundOfUuid?.substring(0, 8) ?? '—',
            _m(o.total.abs()),
          ];
        }(),
    ],
  );
}

ReportTable _drivers(List<OwnerOrder> orders, bool ar) {
  final map = <String, ({int n, double total})>{};
  for (final o in orders) {
    final name = (o.driverName ?? '').trim().isEmpty
        ? (ar ? 'بدون طيار' : 'No driver')
        : o.driverName!.trim();
    final was = map[name];
    map[name] = (n: (was?.n ?? 0) + 1, total: (was?.total ?? 0) + o.total);
  }
  final rows = map.entries.toList()
    ..sort((a, b) => b.value.total.compareTo(a.value.total));
  return ReportTable(
    headers: [
      ar ? 'الطيار' : 'Driver',
      ar ? 'الطلبات' : 'Orders',
      ar ? 'المبيعات' : 'Sales',
    ],
    rows: [
      for (final e in rows) [e.key, '${e.value.n}', _m(e.value.total)],
    ],
  );
}

ReportTable _payments(List<OwnerOrder> orders, bool ar) {
  final map = <String, double>{};
  for (final o in orders) {
    if (o.payments.isEmpty) {
      map['Cash'] = (map['Cash'] ?? 0) + o.total;
      continue;
    }
    for (final p in o.payments) {
      final label =
          (p.label ?? 'Cash').trim().isEmpty ? 'Cash' : p.label!.trim();
      map[label] = (map[label] ?? 0) + p.amount;
    }
  }
  final rows = map.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return ReportTable(
    headers: [ar ? 'الطريقة' : 'Method', ar ? 'المبلغ' : 'Amount'],
    rows: [
      for (final e in rows) [e.key, _m(e.value)],
    ],
  );
}

ReportTable _tax(List<OwnerOrder> orders, bool ar) {
  final net = orders.fold(0.0, (s, o) => s + o.subtotal * o.discountFactor);
  final tax = orders.fold(0.0, (s, o) => s + o.taxTotal);
  final total = orders.fold(0.0, (s, o) => s + o.total);
  return ReportTable(
    headers: [ar ? 'البند' : 'Metric', ar ? 'القيمة' : 'Value'],
    rows: [
      [ar ? 'الأساس' : 'Taxable base', _m(net)],
      [ar ? 'الضريبة' : 'Tax', _m(tax)],
      [ar ? 'الإجمالي شامل الضريبة' : 'Total incl. tax', _m(total)],
    ],
  );
}

ReportTable _revenueCenter(List<OwnerOrder> orders, bool ar) {
  final map = <String, ({int n, double net, double total, double tax})>{};
  for (final o in orders) {
    final key = o.orderType.trim().isEmpty ? '—' : o.orderType.trim();
    final was = map[key];
    map[key] = (
      n: (was?.n ?? 0) + 1,
      net: (was?.net ?? 0) + o.subtotal,
      total: (was?.total ?? 0) + o.total,
      tax: (was?.tax ?? 0) + o.taxTotal,
    );
  }
  final rows = map.entries.toList()
    ..sort((a, b) => b.value.total.compareTo(a.value.total));
  return ReportTable(
    headers: [
      ar ? 'المركز' : 'Center',
      ar ? 'الطلبات' : 'Orders',
      ar ? 'الصافي' : 'Net',
      ar ? 'ضريبة' : 'Tax',
      ar ? 'الإجمالي' : 'Total',
    ],
    rows: [
      for (final e in rows)
        [
          e.key,
          '${e.value.n}',
          _m(e.value.net),
          _m(e.value.tax),
          _m(e.value.total),
        ],
    ],
  );
}

ReportTable _daily(List<OwnerOrder> orders, bool ar) {
  final map = <String, ({int n, double net, double total})>{};
  for (final o in orders) {
    final t = o.createdAt.toLocal();
    final day =
        '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
    final was = map[day];
    map[day] = (
      n: (was?.n ?? 0) + 1,
      net: (was?.net ?? 0) + o.subtotal,
      total: (was?.total ?? 0) + o.total,
    );
  }
  final rows = map.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
  return ReportTable(
    headers: [
      ar ? 'اليوم' : 'Day',
      ar ? 'الطلبات' : 'Orders',
      ar ? 'الصافي' : 'Net',
      ar ? 'الإجمالي' : 'Total',
    ],
    rows: [
      for (final e in rows)
        [e.key, '${e.value.n}', _m(e.value.net), _m(e.value.total)],
    ],
  );
}

ReportTable _modifiers(List<OwnerOrder> orders, bool ar) {
  final map = <String, ({double qty, double net})>{};
  for (final o in orders) {
    for (final l in o.lines) {
      for (final m in l.modifiers) {
        final name = m.name.trim().isEmpty ? '—' : m.name.trim();
        final was = map[name];
        final qty = m.quantity * l.quantity;
        map[name] = (
          qty: (was?.qty ?? 0) + qty,
          net: (was?.net ?? 0) + m.unitPrice * qty,
        );
      }
    }
  }
  final rows = map.entries.toList()
    ..sort((a, b) => b.value.net.compareTo(a.value.net));
  return ReportTable(
    headers: [
      ar ? 'الإضافة' : 'Modifier',
      ar ? 'الكمية' : 'Qty',
      ar ? 'المبيعات' : 'Sales',
    ],
    rows: [
      for (final e in rows) [e.key, _q(e.value.qty), _m(e.value.net)],
    ],
  );
}

ReportTable _compare(
    List<OwnerOrder> current, List<OwnerOrder> previous, bool ar) {
  double tot(List<OwnerOrder> o) => o.fold(0.0, (s, x) => s + x.total);
  final c = tot(current);
  final p = tot(previous);
  final delta = c - p;
  final pct = p == 0 ? (c == 0 ? 0.0 : 100.0) : delta / p * 100;
  return ReportTable(
    headers: [ar ? 'البند' : 'Metric', ar ? 'القيمة' : 'Value'],
    rows: [
      [ar ? 'الفترة الحالية' : 'Current period', _m(c)],
      [ar ? 'الطلبات' : 'Orders', '${current.length}'],
      [ar ? 'الفترة السابقة' : 'Previous period', _m(p)],
      [ar ? 'طلبات سابقة' : 'Previous orders', '${previous.length}'],
      [ar ? 'الفرق' : 'Change', _m(delta)],
      [ar ? 'التغير %' : 'Change %', pct.toStringAsFixed(1)],
    ],
  );
}
