import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/reports/restaurant_analytics.dart';

/// The correctness guardrail for the restaurant report family: a small fixed set
/// of sales (dine-in with a split payment, delivery, takeaway with a line
/// discount, and a refund) across categories with parent types and product costs,
/// asserting every report reconciles to the same net, tax and total.
void main() {
  // Two category levels: a Type (parent) above each Group (child).
  const categories = [
    Category(id: 100, name: 'Food'),
    Category(id: 1, name: 'Pizza', parentId: 100),
    Category(id: 2, name: 'Pasta', parentId: 100),
    Category(id: 200, name: 'Beverages'),
    Category(id: 3, name: 'Soft drinks', parentId: 200),
  ];

  // Product id -> current unit cost.
  const costs = {10: 30.0, 11: 20.0, 12: 5.0};

  final day = DateTime(2026, 8, 12, 12);

  // 1) Dine-in: 2 x Pizza @100, 14% VAT, 12% service, 2 covers, split payment.
  Order dineIn() {
    final o = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      type: OrderType.dineIn,
      serviceChargePercent: 12,
      guestCount: 2,
      tableLabel: 'T1',
      createdAt: day,
      lines: [
        OrderLine(
            productId: 10,
            name: 'Pizza',
            quantity: 2,
            unitPrice: 100,
            categoryId: 1,
            taxRate: 14),
      ],
    );
    // Split the check across two tenders that sum exactly to its total.
    o.payments = [
      OrderPayment(methodId: 1, amount: 150, label: 'Cash'),
      OrderPayment(methodId: -2, amount: o.total - 150, label: 'Card'),
    ];
    return o;
  }

  // 2) Delivery: 1 x Cola @20, 14% VAT, 1 cover, delivery charge.
  Order delivery() => Order(
        deviceId: 'till-1',
        cashierId: 'sara',
        type: OrderType.delivery,
        guestCount: 1,
        deliveryCost: 15,
        createdAt: day,
        lines: [
          OrderLine(
              productId: 12,
              name: 'Cola',
              quantity: 1,
              unitPrice: 20,
              categoryId: 3,
              taxRate: 14),
        ],
      )..payments = [const OrderPayment(methodId: 1, amount: 20, label: 'Cash')];

  // 3) Takeaway: 1 x Pasta @80 with a 10% line discount (a comped line), 1 cover.
  Order takeaway() => Order(
        deviceId: 'till-1',
        cashierId: 'omar',
        type: OrderType.takeaway,
        guestCount: 1,
        createdAt: day,
        lines: [
          OrderLine(
              productId: 11,
              name: 'Pasta',
              quantity: 1,
              unitPrice: 80,
              categoryId: 2,
              taxRate: 14,
              discountPercent: 10),
        ],
      );

  // 4) Refund of one Pizza (negative quantity), same tax and service as the sale.
  Order refund() => Order(
        deviceId: 'till-1',
        cashierId: 'sara',
        type: OrderType.dineIn,
        serviceChargePercent: 12,
        refundOfUuid: 'orig',
        createdAt: day,
        lines: [
          OrderLine(
              productId: 10,
              name: 'Pizza',
              quantity: -1,
              unitPrice: 100,
              categoryId: 1,
              taxRate: 14),
        ],
      );

  List<Order> all() => [dineIn(), delivery(), takeaway(), refund()];

  test('every report reconciles to the same net sales', () {
    final orders = all();
    final groupNet = groupSales(orders, categories, costs)
        .fold(0.0, (s, r) => s + r.net);
    final itemNet =
        itemSales(orders, categories, costs).fold(0.0, (s, r) => s + r.net);
    final sessionNet =
        sessionChecks(orders).fold(0.0, (s, c) => s + c.subtotal);
    final centreNet =
        revenueCentres(orders).fold(0.0, (s, r) => s + r.net);
    final summaryNet = reportTotals(orders, costs).net;

    // 2*100 + 20 + (80*0.9) + (-100) = 192.
    expect(groupNet, closeTo(192, 0.001));
    expect(itemNet, closeTo(groupNet, 0.001));
    expect(sessionNet, closeTo(groupNet, 0.001));
    expect(centreNet, closeTo(groupNet, 0.001));
    expect(summaryNet, closeTo(groupNet, 0.001));
  });

  test('tax and total reconcile across session detail, revenue centre, summary',
      () {
    final orders = all();
    final sessionTax = sessionChecks(orders).fold(0.0, (s, c) => s + c.taxes);
    final centreTax = revenueCentres(orders).fold(0.0, (s, r) => s + r.taxes);
    final summaryTax = reportTotals(orders, costs).taxes;
    expect(centreTax, closeTo(sessionTax, 0.001));
    expect(summaryTax, closeTo(sessionTax, 0.001));

    final sessionTotal = sessionChecks(orders).fold(0.0, (s, c) => s + c.total);
    final centreTotal = revenueCentres(orders).fold(0.0, (s, r) => s + r.total);
    final summaryTotal = reportTotals(orders, costs).total;
    expect(centreTotal, closeTo(sessionTotal, 0.001));
    expect(summaryTotal, closeTo(sessionTotal, 0.001));
  });

  test('cost% is correct for one group and one item', () {
    final orders = all();
    // Pizza group: net 2*100 - 100 = 100, cost 30*(2-1) = 30 -> 30%.
    final pizzaGroup = groupSales(orders, categories, costs)
        .firstWhere((r) => r.group == 'Pizza');
    expect(pizzaGroup.net, closeTo(100, 0.001));
    expect(pizzaGroup.cost, closeTo(30, 0.001));
    expect(pizzaGroup.costPercent, closeTo(30, 0.001));

    final pizzaItem = itemSales(orders, categories, costs)
        .firstWhere((r) => r.name == 'Pizza');
    expect(pizzaItem.costPercent, closeTo(30, 0.001));

    // The Pizza rows sit under the Food type.
    expect(pizzaGroup.type, 'Food');
  });

  test('a split payment shows as multiple tenders summing to the total', () {
    final o = dineIn();
    final check = sessionChecks([o]).single;
    expect(check.tenders.length, 2);
    final tenderSum = check.tenders.fold(0.0, (s, t) => s + t.amount);
    expect(tenderSum, closeTo(check.total, 0.001));
    expect(tenderSum, closeTo(o.total, 0.001));
  });

  test('a refund appears in the refunds summary and reduces totals', () {
    final orders = all();
    final summary = refundSummary(orders);
    expect(summary.count, 1);
    // Refund total: -100 net, -12 service, -15.68 vat -> 127.68 handed back.
    expect(summary.total, closeTo(127.68, 0.001));

    final withRefund = reportTotals(orders, costs).net;
    final withoutRefund =
        reportTotals(orders.where((o) => !o.isRefund).toList(), costs).net;
    expect(withRefund, lessThan(withoutRefund));
    expect(withoutRefund - withRefund, closeTo(100, 0.001));
  });

  test('daily sales per-channel sums add to the day total', () {
    final orders = all();
    final rows = dailySales(orders);
    expect(rows.length, 1);
    final d = rows.single;
    final channelSum = SalesChannel.values.fold(0.0, (s, c) => s + d.channelNet(c));
    expect(channelSum, closeTo(d.net, 0.001));
    expect(d.net, closeTo(192, 0.001));
    // Table service holds the dine-in sale and its refund; delivery and take away
    // hold their own sale.
    expect(d.channelNet(SalesChannel.tableService), closeTo(100, 0.001));
    expect(d.channelNet(SalesChannel.delivery), closeTo(20, 0.001));
    expect(d.channelNet(SalesChannel.takeAway), closeTo(72, 0.001));
  });

  test('revenue centre excludes the refund from counts but not from money', () {
    final orders = all();
    final dine = revenueCentres(orders)
        .firstWhere((r) => r.type == OrderType.dineIn);
    // One real dine-in sale counted, the refund nets its money in but is not a
    // transaction or a cover.
    expect(dine.trans, 1);
    expect(dine.covers, 2);
    expect(dine.net, closeTo(100, 0.001));
  });
}
