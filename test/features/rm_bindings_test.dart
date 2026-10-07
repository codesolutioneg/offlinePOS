import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/reports/rm/rm_bindings.dart';
import 'package:offline_pos/features/reports/rm/rm_layout.dart';
import 'package:offline_pos/features/reports/rm/rm_pdf.dart';
import 'package:offline_pos/features/reports/rm/rm_table_page.dart';

void main() {
  final reports = parseRmReports(
      File('assets/report_layouts/layouts.json').readAsStringSync());
  RmReport named(String id) => reports.firstWhere((r) => r.id == id);

  const categories = [
    Category(id: 1, name: 'Burgers'),
    Category(id: 2, name: 'Drinks'),
  ];
  const costs = {10: 40.0, 20: 5.0};

  Order sale(
    OrderType type, {
    required List<OrderLine> lines,
    List<OrderPayment> payments = const [],
    int? guests,
  }) =>
      Order(deviceId: 'd', cashierId: 'sara', type: type, lines: lines)
        ..payments = payments
        ..guestCount = guests;

  OrderLine burger({double quantity = 1, double discount = 0}) => OrderLine(
        productId: 10,
        name: 'Classic Burger',
        quantity: quantity,
        unitPrice: 100,
        categoryId: 1,
        discountPercent: discount,
      );
  OrderLine cola({double quantity = 1}) => OrderLine(
      productId: 20, name: 'Cola', quantity: quantity, unitPrice: 20, categoryId: 2);

  final orders = [
    sale(OrderType.dineIn,
        lines: [burger(quantity: 2), cola()],
        payments: const [OrderPayment(methodId: 2, amount: 220, label: 'Visa')],
        guests: 2),
    sale(OrderType.takeaway, lines: [burger(discount: 10)]),
  ];

  RmDocument page(String id) {
    final report = named(id);
    final binding = bindRmReport(id,
        orders: orders, categories: categories, costs: costs)!;
    return layOutRmReport(
      report,
      RmSystem(
        shop: 'Chat & Chew',
        report: report.name,
        period: 'Today',
        ranAt: '2026-10-07 16:05',
        filter: 'None',
      ),
      rows: binding.rows,
      headless: binding.headless,
      pageHeading: (items, page, pageWidth) => putRmPageHeading(
        items,
        page: page,
        pageWidth: pageWidth,
        shop: 'Chat & Chew',
        title: report.name,
        period: 'Today',
        filter: 'None',
        ranAt: DateTime(2026, 10, 7, 16, 5),
      ),
    );
  }

  /// What the page shows on the same line as [label], left to right.
  List<String> line(RmDocument doc, String label) {
    final at = doc.items.firstWhere((i) => i.text == label);
    final row = [
      for (final i in doc.items)
        if (i.page == at.page && i.y == at.y && i.text.isNotEmpty) i,
    ]..sort((a, b) => a.x.compareTo(b.x));
    return [for (final i in row) i.text];
  }

  test('a layout nobody connected has no binding', () {
    expect(
        bindRmReport('employeeTimeKeeping',
            orders: orders, categories: categories, costs: costs),
        isNull);
  });

  test('a connected layout shows no field by its name', () {
    for (final id in [
      'SessionSummary',
      'ItemSales',
      'ItemSalesWide',
      'ItemSalesNoPrice',
      'SalesByCategory',
      'SalesByCategoryDetails',
      'PaymentTransactionDetails',
      'PaymentTransactionDetails40',
      'MenuEngineering',
      'groupSalesByEmployee',
      'ItemSalesByCustomerSummary',
      'ItemSalesByCustomerDetail',
      'RefundsSummary',
      'refundDetails',
      'DiscReport',
    ]) {
      expect(page(id).items.where((i) => i.placeholder), isEmpty, reason: id);
    }
  });

  test('session summary: payments are debits, with how many of each', () {
    final doc = page('SessionSummary');
    expect(line(doc, 'Visa'), ['Visa', '1', '220.00']);
    // The untendered take-away is cash for its total.
    expect(line(doc, 'Cash'), ['Cash', '1', '90.00']);
    expect(line(doc, 'Total'), ['Total', '2', '310.00']);
  });

  test('session summary: a refund is not a negative sale, as in the Flash', () {
    final refund = sale(OrderType.dineIn, lines: [burger(quantity: -1)])
      ..refundOfUuid = orders.first.uuid;
    final binding = bindRmReport('SessionSummary',
        orders: [...orders, refund], categories: categories, costs: costs)!;
    final report = named('SessionSummary');
    final doc = layOutRmReport(
      report,
      const RmSystem(
          shop: '', report: '', period: '', ranAt: '', filter: ''),
      rows: binding.rows,
      headless: binding.headless,
    );
    // The takings are what they were without it; the refund is in its own block.
    expect(line(doc, 'Total'), ['Total', '2', '310.00']);
    expect(line(doc, 'Total refunded'), ['Total refunded', '-100.00']);
  });

  test('session summary: a check paid in parts on one tender is one check', () {
    final parts = sale(OrderType.dineIn, lines: [
      burger()
    ], payments: const [
      OrderPayment(methodId: 2, amount: 60, label: 'Visa'),
      OrderPayment(methodId: 2, amount: 40, label: 'Visa'),
    ]);
    final binding = bindRmReport('SessionSummary',
        orders: [parts], categories: categories, costs: costs)!;
    final doc = layOutRmReport(
      named('SessionSummary'),
      const RmSystem(shop: '', report: '', period: '', ranAt: '', filter: ''),
      rows: binding.rows,
      headless: binding.headless,
    );
    expect(line(doc, 'Visa'), ['Visa', '1', '100.00']);
  });

  test('session summary: groups are credits, with discounts and gross', () {
    final doc = page('SessionSummary');
    // Three burgers: 200 + 90 net, 10 given away on the line, 300 gross.
    expect(line(doc, 'Burgers'), ['Burgers', '3', '290.00', '10.00', '300.00']);
    expect(line(doc, 'Drinks'), ['Drinks', '1', '20.00', '0.00', '20.00']);
  });

  test('session summary: the report balances, debit against credit', () {
    final doc = page('SessionSummary');
    expect(line(doc, 'Report Totals:'), ['Report Totals:', '310.00', '310.00']);
  });

  test('session summary: the block the till has nothing for is still there',
      () {
    final doc = page('SessionSummary');
    expect(doc.items.map((i) => i.text), contains('Hash Departments'));
    expect(line(doc, 'Total w/Hash'), ['Total w/Hash', '0']);
    // And a block the till was never asked for is not.
    expect(doc.items.map((i) => i.text), isNot(contains('Account Payments')));
  });

  test('item sales: every item under its group, with the group and report totals',
      () {
    final doc = page('ItemSales');
    expect(line(doc, 'Classic Burger'),
        ['1', 'Classic Burger', '3', '290.00', '120.00', '41.38']);
    expect(line(doc, 'Group Totals:').first, 'Group Totals:');
    expect(line(doc, 'Totals:'), ['Totals:', '4', '310.00', '125.00', '40.32']);
  });

  test('sales by category: a line per category', () {
    final doc = page('SalesByCategory');
    expect(line(doc, 'Burgers'),
        ['1', 'Burgers', '3', '290.00', '120.00', '41.38']);
  });

  test('session summary: costs, discounts by reason and tenders by tip', () {
    final doc = page('SessionSummary');
    expect(line(doc, 'Cost of goods'), ['Cost of goods', '125.00']);
    expect(line(doc, 'Item discounts'), ['Item discounts', '1', '10.00']);
    // Neither check carried a tip, so both tenders are under "without".
    expect(doc.items.map((i) => i.text), contains('Payments Without Tips'));
    expect(line(doc, 'Average check').last, '155.00');
  });

  test('payment transactions: a line per payment, with the check beside it',
      () {
    final doc = page('PaymentTransactionDetails');
    final visa = line(doc, 'Visa');
    expect(visa, containsAll(['220.00', 'Visa', 'sara']));
    expect(line(doc, 'Totals'), containsAll(['310.00']));
  });

  test('menu engineering ranks each dish by the two rules it prints', () {
    final doc = page('MenuEngineering');
    // Three of the four sold and the better earner: kept.
    expect(line(doc, 'Classic Burger').last, 'STAR');
    // A quarter of the mix and under the profit rule: dropped.
    expect(line(doc, 'Cola').last, 'DOG');
  });

  test('group sales by employee: who sold how much of each group', () {
    final doc = page('groupSalesByEmployee');
    expect(line(doc, 'sara'), ['1', 'sara', '3', '290.00', '120.00', '41.38']);
  });

  test('discounts: the item given one, and what was given away in all', () {
    final doc = page('DiscReport');
    expect(line(doc, 'Classic Burger'), contains('10.00'));
    expect(line(doc, 'Total Discounts'), ['Total Discounts', '10.00']);
  });

  test('item sales by customer: a sale with nobody named is a walk-in', () {
    final doc = page('ItemSalesByCustomerSummary');
    expect(line(doc, 'Walk-in'), ['1', 'Walk-in', '4', '310.00']);
  });

  test('the connected layouts save as PDFs', () async {
    final keep = Directory('build/rm-layouts')..createSync(recursive: true);
    for (final id in [
      'SessionSummary',
      'ItemSales',
      'SalesByCategoryDetails',
      'MenuEngineering',
      'PaymentTransactionDetails',
      'DiscReport',
    ]) {
      final bytes = await buildRmPdf(page(id));
      expect(String.fromCharCodes(bytes.take(4)), '%PDF');
      File('${keep.path}/bound-$id.pdf').writeAsBytesSync(bytes);
    }
  });
}
