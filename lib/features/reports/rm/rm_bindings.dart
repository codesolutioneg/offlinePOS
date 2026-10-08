import '../../../domain/catalogue.dart';
import '../../../domain/order.dart';
import '../restaurant_analytics.dart';
import 'rm_layout.dart';

/// A back-office layout's data: the rows for each level it draws, and the levels
/// whose own titles are left off because the level above already carries them.
class RmBinding {
  const RmBinding(this.rows, {this.headless = const {}});

  final Map<String, List<RmRow>> rows;
  final Set<String> headless;
}

/// The till's sales as the data of the back-office layout [id], or null for a
/// layout that is not connected yet.
///
/// The figures are the till's own, read through the same definitions every
/// other report uses (see `restaurant_analytics.dart`); what is the back
/// office's here is which figure goes in which column.
RmBinding? bindRmReport(
  String id, {
  required List<Order> orders,
  required List<Category> categories,
  required Map<int, double> costs,
  Set<int> cashTenderIds = const {},
  Map<String, String> staffNames = const {},
}) =>
    switch (id) {
      'SessionSummary' =>
        _sessionSummary(orders, categories, costs, cashTenderIds),
      'PaymentTransactionDetails' => _paymentTransactions(orders, staffNames),
      'PaymentTransactionDetails40' => _paymentTransactions40(orders),
      'MenuEngineering' => _menuEngineering(orders, categories, costs),
      'groupSalesByEmployee' =>
        _groupSalesByEmployee(orders, categories, costs, staffNames),
      'ItemSalesByCustomerSummary' => _itemSalesByCustomerSummary(orders),
      'ItemSalesByCustomerDetail' =>
        _itemSalesByCustomerDetail(orders, categories, costs),
      // The refunds summary is the item sales layout over the refunds alone.
      'RefundsSummary' => _itemSales(
          orders.where((o) => o.isRefund).toList(), categories, costs),
      'refundDetails' => _refundDetails(orders, staffNames),
      'DiscReport' => _discounts(orders, staffNames),
      'ItemSales' ||
      'ItemSalesWide' ||
      'ItemSalesNoPrice' =>
        _itemSales(orders, categories, costs),
      'SalesByCategory' => _salesByCategory(orders, categories, costs),
      'SalesByCategoryDetails' =>
        _salesByCategoryDetails(orders, categories, costs),
      _ => null,
    };

/// The till report each connected layout stands in for, by the hub's own key.
const rmLayoutForReport = <String, String>{
  'rep-session-summary': 'SessionSummary',
  'rep-item-sales': 'ItemSalesWide',
  'rep-category': 'SalesByCategory',
  'rep-menu-eng': 'MenuEngineering',
  'rep-refunds-summary': 'RefundsSummary',
  'rep-detailed-discounts': 'DiscReport',
};

String _money(double v) => v.toStringAsFixed(2);

String _qty(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

String _percent(double part, double whole) =>
    whole == 0 ? '0.00' : (part / whole * 100).toStringAsFixed(2);

// -- Session Summary -------------------------------------------------------------

RmBinding _sessionSummary(List<Order> all, List<Category> categories,
    Map<int, double> costs, Set<int> cashTenderIds) {
  const root = 'Session Summary';

  // A refund nets out of the takings, the sales and the taxes, as every other
  // report and the Flash count it, so the session's cash is the drawer's. Its
  // own block still says how much was handed back.
  final orders = all;

  // Payments: money in, so a debit. An untendered sale is cash for its total.
  final payments = <String, ({int count, double amount})>{};
  var cash = 0.0;
  var nonCash = 0.0;
  // Number is the checks a tender was taken on, not the times it was keyed: a
  // check paid in three card payments is one card check, as the Flash counts it.
  void tender(String label, double amount,
      {required bool isCash, required bool newCheck}) {
    final was = payments[label];
    payments[label] = (
      count: (was?.count ?? 0) + (newCheck ? 1 : 0),
      amount: (was?.amount ?? 0) + amount,
    );
    isCash ? cash += amount : nonCash += amount;
  }

  for (final o in orders) {
    if (o.payments.isEmpty) {
      tender('Cash', orderTotal(o), isCash: true, newCheck: true);
      continue;
    }
    final seen = <String>{};
    for (final p in o.payments) {
      final label = (p.label ?? '').trim().isEmpty ? 'Cash' : p.label!.trim();
      tender(label, p.amount,
          newCheck: seen.add(label),
          isCash: cashTenderIds.isNotEmpty
              ? cashTenderIds.contains(p.methodId)
              : label.toLowerCase() == 'cash');
    }
  }
  final paid = payments.values.fold<double>(0, (s, p) => s + p.amount);
  final paidCount = payments.values.fold<int>(0, (s, p) => s + p.count);

  // Groups: what was sold, a credit, with what each group gave away in line
  // discounts beside it and the two together as its gross.
  final byId = {for (final c in categories) c.id: c};
  final groups = <String, ({double qty, double net, double discount})>{};
  for (final o in orders) {
    for (final l in o.lines) {
      final name = categoryPath(l.categoryId, byId).group;
      final was = groups[name];
      groups[name] = (
        qty: (was?.qty ?? 0) + l.quantity,
        net: (was?.net ?? 0) + l.total,
        discount:
            (was?.discount ?? 0) + l.gross * l.discountPercent / 100,
      );
    }
  }
  final groupQty = groups.values.fold<double>(0, (s, g) => s + g.qty);
  final groupNet = groups.values.fold<double>(0, (s, g) => s + g.net);
  final groupDiscount =
      groups.values.fold<double>(0, (s, g) => s + g.discount);

  // Taxes: the service charge and the VAT, each over the checks that carry it.
  final service = orders.fold<double>(0, (s, o) => s + orderService(o));
  final vat = orders.fold<double>(0, (s, o) => s + orderVat(o));
  final serviceChecks = orders.where((o) => orderService(o) != 0).length;
  final vatChecks = orders.where((o) => orderVat(o) != 0).length;

  // Everything else that moves the total: tips and delivery charged on top, and
  // the whole-check discounts taken off it.
  final tips = orders.fold<double>(0, (s, o) => s + o.tip);
  final delivery = orders.fold<double>(0, (s, o) => s + o.deliveryCost);
  final checkDiscount =
      orders.fold<double>(0, (s, o) => s + orderCheckDiscount(o));
  final others = <RmRow>[
    if (tips != 0)
      RmRow({
        'Description': 'Tips',
        'Number': '${orders.where((o) => o.tip != 0).length}',
        'Credit': _money(tips),
        'Net Tips': _money(tips),
      }),
    if (delivery != 0)
      RmRow({
        'Description': 'Delivery charges',
        'Number': '${orders.where((o) => o.deliveryCost != 0).length}',
        'Credit': _money(delivery),
      }),
    if (checkDiscount != 0)
      RmRow({
        'Description': 'Check discounts',
        'Number': '${orders.where((o) => orderCheckDiscount(o) != 0).length}',
        'Debit': _money(checkDiscount),
        'Discounts': _money(checkDiscount),
      }),
  ];
  final otherCredit = tips + delivery;

  final debit = paid + checkDiscount;
  final credit = groupNet + service + vat + otherCredit;

  final centres = revenueCentres(orders);
  final covers = centres.fold<int>(0, (s, c) => s + c.covers);
  final trans = centres.fold<int>(0, (s, c) => s + c.trans);
  final centreNet = centres.fold<double>(0, (s, c) => s + c.net);
  final centreTotal = centres.fold<double>(0, (s, c) => s + c.total);

  // What the goods sold cost, and what was handed back.
  final cost = orders.fold<double>(
      0,
      (s, o) =>
          s +
          o.lines.fold<double>(
              0, (t, l) => t + (costs[l.productId] ?? 0) * l.quantity));
  final refunds = all
      .where((o) => o.isRefund)
      .fold<double>(0, (s, o) => s + orderTotal(o));

  // Discounts by what they were given for: the items' own as one line, the
  // whole-check ones under the reason each was given.
  final discounted = <String, ({int count, double amount})>{};
  void gave(String why, double amount) {
    final was = discounted[why];
    discounted[why] =
        (count: (was?.count ?? 0) + 1, amount: (was?.amount ?? 0) + amount);
  }

  for (final o in orders) {
    for (final l in o.lines) {
      if (l.discountPercent != 0) {
        gave('Item discounts', l.gross * l.discountPercent / 100);
      }
    }
    final off = orderCheckDiscount(o);
    if (off != 0) {
      final why = (o.discountReason ?? '').trim();
      gave(why.isEmpty ? 'Check discount' : why, off);
    }
  }

  // Payments by tender, apart by whether the check they settled carried a tip.
  List<RmRow> tenders(bool tipped, {required bool total}) {
    final by = <String, ({int count, double amount, double tip})>{};
    for (final p in _paymentsOf(orders)) {
      if ((p.order.tip != 0) != tipped) continue;
      final was = by[p.label];
      by[p.label] = (
        count: (was?.count ?? 0) + 1,
        amount: (was?.amount ?? 0) + p.amount,
        tip: (was?.tip ?? 0) + (p.first ? p.order.tip : 0),
      );
    }
    if (total) {
      return [
        RmRow({
          'Pay Type': 'Total',
          'Qty': '${by.values.fold<int>(0, (s, v) => s + v.count)}',
          'Amount':
              _money(by.values.fold<double>(0, (s, v) => s + v.amount)),
          'Grat/Tip': _money(by.values.fold<double>(0, (s, v) => s + v.tip)),
        }),
      ];
    }
    return [
      for (final e in by.entries)
        RmRow({
          'Pay Type': e.key,
          'Qty': '${e.value.count}',
          'Amount': _money(e.value.amount),
          'Grat/Tip': _money(e.value.tip),
        }),
    ];
  }

  return RmBinding({
    '$root.Payment Types.Payment Types Detail': [
      for (final e in payments.entries)
        RmRow({
          'Description': e.key,
          'Number': '${e.value.count}',
          'Debit': _money(e.value.amount),
        }),
    ],
    '$root.Payment totals': [
      RmRow({
        'Description': 'Total',
        'Number': '$paidCount',
        'Debit': _money(paid),
      }),
    ],
    '$root.Group Types.Group Types Detail': [
      for (final e in groups.entries)
        RmRow({
          'Description': e.key,
          'Number': _qty(e.value.qty),
          'Credit': _money(e.value.net),
          'Discounts': _money(e.value.discount),
          'Gross Sales': _money(e.value.net + e.value.discount),
        }),
    ],
    '$root.Group totals': [
      RmRow({
        'Number': _qty(groupQty),
        'Credit': _money(groupNet),
        'Discounts': _money(groupDiscount),
        'Gross Sales': _money(groupNet + groupDiscount),
      }),
    ],
    // The till keeps no hash departments: the block is there, and empty.
    '$root.Hash Dept Group Types.Hash Dept Group Types Detail': const [],
    '$root.Hash Dept Group totals': const [
      RmRow({'Description': 'Total w/Hash', 'Number': '0'}),
    ],
    '$root.Taxes Types.Taxes Types Detail': [
      RmRow({
        'Description': 'Service',
        'Number': '$serviceChecks',
        'Credit': _money(service),
      }),
      RmRow({
        'Description': 'VAT',
        'Number': '$vatChecks',
        'Credit': _money(vat),
      }),
    ],
    '$root.Taxes totals': [
      RmRow({
        'Number': '${serviceChecks + vatChecks}',
        'Credit': _money(service + vat),
      }),
    ],
    '$root.Other Types.Others Types Detail': others,
    '$root.Others totals': [
      RmRow({
        'Number': '${others.length}',
        'Debit': checkDiscount == 0 ? '' : _money(checkDiscount),
        'Credit': _money(otherCredit),
        'Discounts': checkDiscount == 0 ? '' : _money(checkDiscount),
        'Net Tips': _money(tips),
      }),
    ],
    '$root.Report Totals': [
      RmRow({'Debit': _money(debit), 'Credit': _money(credit)}),
    ],
    '$root.Cash vs Non-cash Sales Item.Cash vs Non-cash Sales Item detail': [
      RmRow({
        'Payment': 'Cash',
        'Sales': _money(cash),
        '% Total': _percent(cash, cash + nonCash),
      }),
      RmRow({
        'Payment': 'Non-cash',
        'Sales': _money(nonCash),
        '% Total': _percent(nonCash, cash + nonCash),
      }),
    ],
    '$root.Cash vs Non-cash Sales Total': [
      RmRow({
        'Sales': _money(cash + nonCash),
        '% Total': cash + nonCash == 0 ? '0.00' : '100.00',
      }),
    ],
    '$root.Revenue Centers.Revenue Center Item': [
      for (final c in centres)
        RmRow({
          'Revenue Center': c.type.label,
          'Cust': '${c.covers}',
          'Net Sales': _money(c.net),
          'Gross Sales': _money(c.total),
          'Trans Avg': _money(c.transAvg),
          'Customer Avg': _money(c.customerAvg),
        }),
    ],
    '$root.Revenue Centers Totals': [
      RmRow({
        'Cust': '$covers',
        'Net Sales': _money(centreNet),
        'Gross Sales': _money(centreTotal),
        'Trans Avg': _money(trans == 0 ? 0 : centreTotal / trans),
        'Customer Avg': _money(covers == 0 ? 0 : centreTotal / covers),
      }),
    ],
    // The till reports settled checks only, so nothing here is still open.
    '$root.Total and average item': [
      RmRow(const {}, children: {
        'Tot and avg detail': [
          RmRow({
            'Descr': 'Sales',
            'Settled': _money(groupNet),
            'Open': '0.00',
            'Total': _money(groupNet),
            '% Settled': '100',
            'Avg Descr': 'Average check',
            'Amount': _money(trans == 0 ? 0 : centreTotal / trans),
          }),
          RmRow({
            'Descr': 'Customers',
            'Settled': '$covers',
            'Open': '0',
            'Total': '$covers',
            '% Settled': '100',
            'Avg Descr': 'Average customer spend',
            'Amount': _money(covers == 0 ? 0 : centreTotal / covers),
          }),
          RmRow({
            'Descr': 'Checks',
            'Settled': '$trans',
            'Open': '0',
            'Total': '$trans',
            '% Settled': '100',
          }),
        ],
      }),
    ],
    '$root.Cost Item': [
      RmRow(const {}, children: {
        'Cost Item detail': [
          RmRow({'Desc': 'Cost of goods', 'Amount': _money(cost)}),
          RmRow({'Desc': 'Cost %', 'Amount': _percent(cost, groupNet)}),
        ],
      }),
    ],
    '$root.Payments with tips.Payments with tips Detail':
        tenders(true, total: false),
    '$root.Payments with tips totals': tenders(true, total: true),
    '$root.Payments without tips.Payments without tips Detail':
        tenders(false, total: false),
    '$root.Payments without tips totals': tenders(false, total: true),
    '$root.Refunds Item.Refunds Item detail': [
      RmRow({'Desc': 'Total refunded', 'Amount': _money(refunds)}),
    ],
    '$root.Discounts Subdetail Item.Discount Item Subdetail': [
      for (final e in discounted.entries)
        RmRow({
          'Desc': e.key,
          'Qty': '${e.value.count}',
          'Amount': _money(e.value.amount),
        }),
    ],
    '$root.Discounts Subdetail Totals': [
      RmRow({
        'Desc': 'Total',
        'Qty': '${discounted.values.fold<int>(0, (s, v) => s + v.count)}',
        'Amount': _money(
            discounted.values.fold<double>(0, (s, v) => s + v.amount)),
      }),
    ],
  }, headless: const {
    '$root.Payments with tips totals',
    '$root.Payments without tips totals',
    '$root.Discounts Subdetail Totals',
    // A totals line sits under the rule that closes its table; the titles it
    // was designed with are the table's own, set again.
    '$root.Hash Dept Group totals',
    '$root.Cash vs Non-cash Sales Total',
    '$root.Revenue Centers Totals',
  });
}

// -- Item sales -------------------------------------------------------------------

RmBinding _itemSales(
    List<Order> orders, List<Category> categories, Map<int, double> costs) {
  const root = 'Flattened Item grouped by Menu Item grouped by Group Numbers';
  final items = itemSales(orders, categories, costs);
  final groups = <String, List<ItemSalesRow>>{};
  for (final i in items) {
    groups.putIfAbsent(i.group, () => []).add(i);
  }
  final qty = items.fold<double>(0, (s, i) => s + i.qty);
  final net = items.fold<double>(0, (s, i) => s + i.net);
  final cost = items.fold<double>(0, (s, i) => s + i.cost);

  var groupNo = 0;
  var itemNo = 0;
  return RmBinding({
    root: [
      RmRow({
        'Total Quantity': _qty(qty),
        'Total Revenues': _money(net),
        'Total Cost': _money(cost),
        'Total Cost %': _percent(cost, net),
      }, children: {
        'Group': [
          for (final e in groups.entries)
            () {
              final gQty = e.value.fold<double>(0, (s, i) => s + i.qty);
              final gNet = e.value.fold<double>(0, (s, i) => s + i.net);
              final gCost = e.value.fold<double>(0, (s, i) => s + i.cost);
              return RmRow({
                'Group Numbers': '${++groupNo}',
                'Group Name': e.key,
                'Group Quantity': _qty(gQty),
                'Group Revenue': _money(gNet),
                'Group Cost': _money(gCost),
                'Group Cost %': _percent(gCost, gNet),
              }, children: {
                'Flattened Item grouped by Menu Item Detail': [
                  for (final i in e.value)
                    RmRow({
                      'Menu Item': '${++itemNo}',
                      'Description': i.name,
                      'Item Quantity': _qty(i.qty),
                      'Item Revenue': _money(i.net),
                      'Item Cost': _money(i.cost),
                      'Item Cost %': _percent(i.cost, i.net),
                    }),
                ],
              });
            }(),
        ],
      }),
    ],
  });
}

// -- Sales by category --------------------------------------------------------------

RmBinding _salesByCategory(
    List<Order> orders, List<Category> categories, Map<int, double> costs) {
  var no = 0;
  return RmBinding({
    'Flattened Category grouped by Category.Group': [
      for (final g in groupSales(orders, categories, costs))
        RmRow({
          'Category': '${++no}',
          'CategoryName': g.group,
          'Quantity': _qty(g.qty),
          'Sales': _money(g.net),
          'Cost': _money(g.cost),
          'Cost %': _percent(g.cost, g.net),
        }),
    ],
  });
}

RmBinding _salesByCategoryDetails(
    List<Order> orders, List<Category> categories, Map<int, double> costs) {
  final groups = <String, List<ItemSalesRow>>{};
  for (final i in itemSales(orders, categories, costs)) {
    groups.putIfAbsent(i.group, () => []).add(i);
  }
  var no = 0;
  var itemNo = 0;
  return RmBinding({
    'Flattened Category grouped by Category grouped by Menu Item.Group': [
      for (final e in groups.entries)
        () {
          final qty = e.value.fold<double>(0, (s, i) => s + i.qty);
          final net = e.value.fold<double>(0, (s, i) => s + i.net);
          final cost = e.value.fold<double>(0, (s, i) => s + i.cost);
          return RmRow({
            'Category': '${++no}',
            'CategoryName': e.key,
            'Quantity': _qty(qty),
            'Sales': _money(net),
            'Cost': _money(cost),
            'Cost %': _percent(cost, net),
          }, children: {
            'Group': [
              for (final i in e.value)
                RmRow({
                  'Menu Item': '${++itemNo}',
                  'Description': i.name,
                  'Quantity': _qty(i.qty),
                  'Sales': _money(i.net),
                  'Cost': _money(i.cost),
                  'Cost %': _percent(i.cost, i.net),
                }),
            ],
          });
        }(),
    ],
  });
}

// -- Shared helpers ----------------------------------------------------------------

String _two(int n) => n.toString().padLeft(2, '0');

String _date(DateTime at) {
  final l = at.toLocal();
  return '${l.year}-${_two(l.month)}-${_two(l.day)}';
}

String _time(DateTime at) {
  final l = at.toLocal();
  return '${_two(l.hour)}:${_two(l.minute)}';
}

String _staff(String id, Map<String, String> names) => names[id] ?? id;

/// The cashiers in [orders], numbered in the order they first appear, since the
/// till knows its staff by id rather than by an employee number.
Map<String, int> _staffNumbers(Iterable<Order> orders) {
  final out = <String, int>{};
  for (final o in orders) {
    out.putIfAbsent(o.cashierId, () => out.length + 1);
  }
  return out;
}

// -- Payment transactions -----------------------------------------------------------

/// One payment taken, with the check it was taken against.
typedef _Payment = ({Order order, String label, double amount, bool first});

List<_Payment> _paymentsOf(List<Order> orders) => [
      for (final o in orders)
        if (o.payments.isEmpty)
          (order: o, label: 'Cash', amount: orderTotal(o), first: true)
        else
          for (var i = 0; i < o.payments.length; i++)
            (
              order: o,
              label: o.payments[i].label ?? 'Cash',
              amount: o.payments[i].amount,
              first: i == 0,
            ),
    ];

RmBinding _paymentTransactions(
    List<Order> orders, Map<String, String> staffNames) {
  final payments = _paymentsOf(orders);
  return RmBinding({
    'Sls And Pmt Report': [
      RmRow({
        'Sub Total': _money(orders.fold<double>(0, (s, o) => s + orderNet(o))),
        'Taxes': _money(orders.fold<double>(0, (s, o) => s + orderTaxes(o))),
        'Total': _money(orders.fold<double>(0, (s, o) => s + orderTotal(o))),
        'Tip': _money(orders.fold<double>(0, (s, o) => s + o.tip)),
        'Payment Amt':
            _money(payments.fold<double>(0, (s, p) => s + p.amount)),
      }, children: {
        'SlsPmt record': [
          for (final p in payments)
            RmRow({
              'Order Number': p.order.displayNo,
              // A check split over several tenders says its own figures once.
              'Sub Total': p.first ? _money(orderNet(p.order)) : '',
              'Taxes': p.first ? _money(orderTaxes(p.order)) : '',
              'Total': p.first ? _money(orderTotal(p.order)) : '',
              'Tip': p.first ? _money(p.order.tip) : '',
              'Payment Amt': _money(p.amount),
              'Payment Type': p.label,
              'Auth Date': _date(p.order.createdAt),
              'Auth Time': _time(p.order.createdAt),
              'Table/Ref': p.order.tableLabel ?? '',
              'Employee': _staff(p.order.cashierId, staffNames),
            }),
        ],
      }),
    ],
  });
}

RmBinding _paymentTransactions40(List<Order> orders) {
  final payments = _paymentsOf(orders);
  final types = <String, int>{};
  for (final p in payments) {
    types.putIfAbsent(p.label, () => types.length + 1);
  }
  return RmBinding({
    'Sls And Pmt Report.PaymentList': [
      RmRow({
        'Total': _money(orders.fold<double>(0, (s, o) => s + orderTotal(o))),
        'Tip2': _money(orders.fold<double>(0, (s, o) => s + o.tip)),
        'Pmt Amt2': _money(payments.fold<double>(0, (s, p) => s + p.amount)),
        'Count of SlsPmt record': '${payments.length}',
      }, children: {
        'SlsPmt record': [
          for (final p in payments)
            RmRow({
              'Order': p.order.displayNo,
              'PT': '${types[p.label]}',
              'Total': p.first ? _money(orderTotal(p.order)) : '',
              'Tip': p.first ? _money(p.order.tip) : '',
              'Pmt Amt': _money(p.amount),
            }),
        ],
      }),
    ],
    'Sls And Pmt Report.Pay Type Legend.A Pay Type': [
      for (final e in types.entries)
        RmRow({'PayNo': '${e.value}', 'PayName': e.key}),
    ],
  });
}

// -- Menu engineering ----------------------------------------------------------------

RmBinding _menuEngineering(
    List<Order> orders, List<Category> categories, Map<int, double> costs) {
  // One line per dish, whatever group it sits in.
  final dishes = <String, ({double qty, double net, double cost})>{};
  for (final i in itemSales(orders, categories, costs)) {
    final was = dishes[i.name];
    dishes[i.name] = (
      qty: (was?.qty ?? 0) + i.qty,
      net: (was?.net ?? 0) + i.net,
      cost: (was?.cost ?? 0) + i.cost,
    );
  }
  final qty = dishes.values.fold<double>(0, (s, d) => s + d.qty);
  final net = dishes.values.fold<double>(0, (s, d) => s + d.net);
  final cost = dishes.values.fold<double>(0, (s, d) => s + d.cost);
  final profit = net - cost;
  // The two rules the layout prints under the table and ranks every dish by.
  final mixRule = dishes.isEmpty ? 0.0 : 1 / dishes.length * 70;
  final profitRule = qty == 0 ? 0.0 : profit / qty;

  var no = 0;
  return RmBinding({
    'Flattened Category grouped by Menu Item': [
      RmRow({
        'TotalQuantity': _qty(qty),
        'TotalRevenue': _money(net),
        'TotalCost': _money(cost),
        'TotalProfit': _money(profit),
        'Menu Mix Rule %': _money(mixRule),
        'Profit Contribution Rule': _money(profitRule),
      }, children: {
        'Group': [
          for (final e in dishes.entries)
            () {
              final d = e.value;
              final mix = qty == 0 ? 0.0 : d.qty / qty * 100;
              final avgProfit = d.qty == 0 ? 0.0 : (d.net - d.cost) / d.qty;
              final popular = mix > mixRule;
              final earning = avgProfit > profitRule;
              return RmRow({
                'Item #': '${++no}',
                'Item Description': e.key,
                'Quantity': _qty(d.qty),
                'Menu Mix %': _money(mix),
                'Avg. Price': _money(d.qty == 0 ? 0 : d.net / d.qty),
                'Avg. Cost': _money(d.qty == 0 ? 0 : d.cost / d.qty),
                'Avg. Profit': _money(avgProfit),
                'Total Sales': _money(d.net),
                'Total Cost': _money(d.cost),
                'Total Profit': _money(d.net - d.cost),
                'Profit Margin': _percent(d.net - d.cost, d.net),
                'Rank': popular
                    ? (earning ? 'STAR' : 'WORKHORSE')
                    : (earning ? 'CHALLENGE' : 'DOG'),
              });
            }(),
        ],
      }),
    ],
  });
}

// -- Group sales by employee -----------------------------------------------------------

RmBinding _groupSalesByEmployee(
  List<Order> orders,
  List<Category> categories,
  Map<int, double> costs,
  Map<String, String> staffNames,
) {
  final byId = {for (final c in categories) c.id: c};
  final numbers = _staffNumbers(orders);
  final groups =
      <String, Map<String, ({double qty, double net, double cost})>>{};
  for (final o in orders) {
    for (final l in o.lines) {
      final group = categoryPath(l.categoryId, byId).group;
      final staff = groups.putIfAbsent(group, () => {});
      final was = staff[o.cashierId];
      staff[o.cashierId] = (
        qty: (was?.qty ?? 0) + l.quantity,
        net: (was?.net ?? 0) + l.total,
        cost: (was?.cost ?? 0) + (costs[l.productId] ?? 0) * l.quantity,
      );
    }
  }
  var qty = 0.0, net = 0.0, cost = 0.0, no = 0;
  final rows = <RmRow>[];
  for (final g in groups.entries) {
    final gQty = g.value.values.fold<double>(0, (s, v) => s + v.qty);
    final gNet = g.value.values.fold<double>(0, (s, v) => s + v.net);
    final gCost = g.value.values.fold<double>(0, (s, v) => s + v.cost);
    qty += gQty;
    net += gNet;
    cost += gCost;
    rows.add(RmRow({
      'Group Numbers': '${++no}',
      'Group Name': g.key,
      'Group Quantity': _qty(gQty),
      'Group revenues': _money(gNet),
      'Group Cost': _money(gCost),
      'Group Cost %': _percent(gCost, gNet),
    }, children: {
      'Group': [
        for (final e in g.value.entries)
          RmRow({
            'Employee': '${numbers[e.key]}',
            'Employee name': _staff(e.key, staffNames),
            'Quantity': _qty(e.value.qty),
            'Revenues': _money(e.value.net),
            'Item Cost': _money(e.value.cost),
            'Employee Cost %': _percent(e.value.cost, e.value.net),
          }),
      ],
    }));
  }
  return RmBinding({
    'Flattened Item grouped by Group Numbers grouped by Employee': [
      RmRow({
        'Report Quantity': _qty(qty),
        'Report Revenues': _money(net),
        'Report Cost': _money(cost),
        'Report Cost %': _percent(cost, net),
      }, children: {
        'Group': rows
      }),
    ],
  });
}

// -- Item sales by customer ------------------------------------------------------------

/// The sales in [orders] under whoever they were rung for. A sale with nobody
/// named on it is a walk-in.
Map<String, List<Order>> _byCustomer(List<Order> orders) {
  final out = <String, List<Order>>{};
  for (final o in orders) {
    final name = (o.customerName ?? '').trim();
    out.putIfAbsent(name.isEmpty ? 'Walk-in' : name, () => []).add(o);
  }
  return out;
}

RmBinding _itemSalesByCustomerSummary(List<Order> orders) {
  final customers = _byCustomer(orders);
  var qty = 0.0, net = 0.0, no = 0;
  final rows = <RmRow>[];
  for (final c in customers.entries) {
    final lines = c.value.expand((o) => o.lines);
    final cQty = lines.fold<double>(0, (s, l) => s + l.quantity);
    final cNet = lines.fold<double>(0, (s, l) => s + l.total);
    qty += cQty;
    net += cNet;
    rows.add(RmRow({
      'Customer #': '${++no}',
      'Customer Name': c.key,
      'Qty': _qty(cQty),
      'Revenue': _money(cNet),
    }));
  }
  return RmBinding({
    'Sales By Customer grouped by Customer #': [
      RmRow({'Qty': _qty(qty), 'Revenue': _money(net)},
          children: {'Group': rows}),
    ],
  });
}

RmBinding _itemSalesByCustomerDetail(
    List<Order> orders, List<Category> categories, Map<int, double> costs) {
  var qty = 0.0, net = 0.0, no = 0;
  final rows = <RmRow>[];
  for (final c in _byCustomer(orders).entries) {
    final groups = <String, List<ItemSalesRow>>{};
    for (final i in itemSales(c.value, categories, costs)) {
      groups.putIfAbsent(i.group, () => []).add(i);
    }
    var cQty = 0.0, cNet = 0.0, groupNo = 0, itemNo = 0;
    final groupRows = <RmRow>[];
    for (final g in groups.entries) {
      final gQty = g.value.fold<double>(0, (s, i) => s + i.qty);
      final gNet = g.value.fold<double>(0, (s, i) => s + i.net);
      cQty += gQty;
      cNet += gNet;
      groupRows.add(RmRow({
        'Group': '${++groupNo}',
        'Group Name': g.key,
        'Qty': _qty(gQty),
        'Revenue': _money(gNet),
      }, children: {
        'Group': [
          for (final i in g.value)
            RmRow({
              'Menu Item': '${++itemNo}',
              'Description': i.name,
              'Qty': _qty(i.qty),
              'Revenue': _money(i.net),
            }),
        ],
      }));
    }
    qty += cQty;
    net += cNet;
    rows.add(RmRow({
      'Customer #': '${++no}',
      'Customer Name': c.key,
      'Qty': _qty(cQty),
      'Revenue': _money(cNet),
    }, children: {
      'Group': groupRows
    }));
  }
  return RmBinding({
    'Sales By Customer grouped by Customer # grouped by Group grouped by Menu Item':
        [
      RmRow({'Qty': _qty(qty), 'Revenue': _money(net)},
          children: {'Group': rows}),
    ],
  });
}

// -- Refunds ---------------------------------------------------------------------------

RmBinding _refundDetails(List<Order> orders, Map<String, String> staffNames) {
  final refunds = orders.where((o) => o.isRefund).toList();
  final lines = [
    for (final o in refunds)
      for (final l in o.lines) (order: o, line: l),
  ];
  return RmBinding({
    'Flattened Item': [
      RmRow({
        'Quantity': _qty(lines.fold<double>(0, (s, e) => s + e.line.quantity)),
        'Amount': _money(lines.fold<double>(0, (s, e) => s + e.line.total)),
      }, children: {
        'Flattened Item Detail': [
          for (final e in lines)
            RmRow({
              'Open Date': _date(e.order.createdAt),
              'Open Time': _time(e.order.createdAt),
              'Order number': e.order.displayNo,
              'Quantity': _qty(e.line.quantity),
              'ITEM_DESC_CALC': e.line.name,
              'Amount': _money(e.line.total),
              'Empl name': _staff(e.order.cashierId, staffNames),
              'Refunded by': _staff(e.order.cashierId, staffNames),
              'Payment type': e.order.payments.isEmpty
                  ? 'Cash'
                  : (e.order.payments.first.label ?? 'Cash'),
            }),
        ],
      }),
    ],
  });
}

// -- Discounts ---------------------------------------------------------------------------

RmBinding _discounts(List<Order> orders, Map<String, String> staffNames) {
  final numbers = _staffNumbers(orders);

  // Items given a discount of their own, under who rang them and on which check.
  final itemRows = <RmRow>[];
  var itemTotal = 0.0;
  // Whole checks discounted, under who rang them.
  final checkRows = <RmRow>[];
  var checkTotal = 0.0;

  for (final staff in numbers.keys) {
    final theirs = orders.where((o) => o.cashierId == staff);
    final byOrder = <RmRow>[];
    var staffItems = 0.0;
    final checks = <RmRow>[];
    var staffChecks = 0.0;
    for (final o in theirs) {
      final discounted = [
        for (final l in o.lines)
          if (l.discountPercent != 0) l,
      ];
      if (discounted.isNotEmpty) {
        final off = discounted.fold<double>(
            0, (s, l) => s + l.gross * l.discountPercent / 100);
        staffItems += off;
        byOrder.add(RmRow({
          'Total Discount': _money(off)
        }, children: {
          'Flattened Item grouped by Employee number Detail': [
            for (final l in discounted)
              RmRow({
                'Date': _date(o.createdAt),
                'Table': o.tableLabel ?? '',
                'Order #': o.displayNo,
                'Total Check': _money(orderTotal(o)),
                'Item Name': l.name,
                'Discount': _money(l.gross * l.discountPercent / 100),
                'Reference': o.discountReason ?? '',
              }),
          ],
        }));
      }
      final off = orderCheckDiscount(o);
      if (off != 0) {
        staffChecks += off;
        checks.add(RmRow({
          'Date': _date(o.createdAt),
          'Table #': o.tableLabel ?? '',
          'Order #': o.displayNo,
          'Total Check': _money(orderTotal(o)),
          'Account': o.customerName ?? '',
          'Discount': _money(off),
          'Reference': o.discountReason ?? '',
        }));
      }
    }
    if (byOrder.isNotEmpty) {
      itemTotal += staffItems;
      itemRows.add(RmRow({
        'Employee number': '${numbers[staff]}',
        'Employee name': _staff(staff, staffNames),
        'Total Employee Discounts': _money(staffItems),
      }, children: {
        'Group': byOrder
      }));
    }
    if (checks.isNotEmpty) {
      checkTotal += staffChecks;
      checkRows.add(RmRow({
        'Employee': '${numbers[staff]}',
        'Employee name': _staff(staff, staffNames),
        'Check discount amount': _money(staffChecks),
      }, children: {
        'Flattened Items Detail': checks
      }));
    }
  }

  final sales = orders.fold<double>(0, (s, o) => s + orderNet(o));
  return RmBinding({
    'Flattened Item grouped by Employee number grouped by Order number.Group':
        itemRows,
    'Flattened Items grouped by Employee.Group': checkRows,
    'Flattened Item': [
      RmRow({
        'Total Item Discounts': _money(itemTotal),
        'Total CDiscounts': _money(checkTotal),
        'Real Total Discounts': _money(itemTotal + checkTotal),
        'Total Sales': _money(sales),
        'Disc % of Sales': _percent(itemTotal + checkTotal, sales),
      }),
    ],
  });
}
