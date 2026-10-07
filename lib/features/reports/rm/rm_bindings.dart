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
}) =>
    switch (id) {
      'SessionSummary' => _sessionSummary(orders, categories, cashTenderIds),
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
};

String _money(double v) => v.toStringAsFixed(2);

String _qty(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

String _percent(double part, double whole) =>
    whole == 0 ? '0.00' : (part / whole * 100).toStringAsFixed(2);

// -- Session Summary -------------------------------------------------------------

RmBinding _sessionSummary(
    List<Order> orders, List<Category> categories, Set<int> cashTenderIds) {
  const root = 'Session Summary';

  // Payments: money in, so a debit. An untendered sale is cash for its total.
  final payments = <String, ({int count, double amount})>{};
  var cash = 0.0;
  var nonCash = 0.0;
  void tender(String label, double amount, {required bool isCash}) {
    final was = payments[label];
    payments[label] =
        (count: (was?.count ?? 0) + 1, amount: (was?.amount ?? 0) + amount);
    isCash ? cash += amount : nonCash += amount;
  }

  for (final o in orders) {
    if (o.payments.isEmpty) {
      tender('Cash', orderTotal(o), isCash: true);
      continue;
    }
    for (final p in o.payments) {
      final label = p.label ?? 'Cash';
      tender(label, p.amount,
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
  }, headless: const {
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
