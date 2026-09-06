import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/reports/daily_sales_report_screen.dart';
import 'package:offline_pos/features/reports/detailed_discounts_report_screen.dart';
import 'package:offline_pos/features/reports/group_sales_report_screen.dart';
import 'package:offline_pos/features/reports/item_sales_report_screen.dart';
import 'package:offline_pos/features/reports/refunds_summary_report_screen.dart';
import 'package:offline_pos/features/reports/revenue_center_report_screen.dart';
import 'package:offline_pos/features/reports/session_detail_report_screen.dart';
import 'package:offline_pos/features/reports/session_summary_report_screen.dart';

/// Smoke tests that every new restaurant report screen renders its content for a
/// small order set, on a window tall enough not to overflow the cards.
void main() {
  const categories = [
    Category(id: 100, name: 'Food'),
    Category(id: 1, name: 'Pizza', parentId: 100),
    Category(id: 200, name: 'Beverages'),
    Category(id: 3, name: 'Soft drinks', parentId: 200),
  ];
  const costs = {10: 30.0, 12: 5.0};
  final day = DateTime(2026, 8, 12, 12);

  Order dineIn() {
    final o = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      type: OrderType.dineIn,
      serviceChargePercent: 12,
      guestCount: 2,
      tableLabel: 'T1',
      discountPercent: 10,
      discountReason: 'Loyalty',
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
    o.payments = [
      OrderPayment(methodId: 1, amount: 150, label: 'Cash'),
      OrderPayment(methodId: -2, amount: o.total - 150, label: 'Card'),
    ];
    return o;
  }

  Order delivery() => Order(
        deviceId: 'till-1',
        cashierId: 'sara',
        type: OrderType.delivery,
        guestCount: 1,
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
      );

  List<Order> orders() => [dineIn(), delivery()];

  void tall(WidgetTester t) {
    t.view.physicalSize = const Size(1000, 4000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

  String money(double v) => v.toStringAsFixed(2);
  Widget wrap(Widget child) => MaterialApp(home: child);

  testWidgets('group sales renders its grand total', (t) async {
    tall(t);
    await t.pumpWidget(wrap(GroupSalesReportScreen(
        orders: orders(),
        categories: categories,
        costs: costs,
        formatAmount: money)));
    expect(find.byKey(const Key('group-sales-list')), findsOneWidget);
    expect(find.byKey(const Key('group-sales-grand')), findsOneWidget);
  });

  testWidgets('item sales renders its grand total', (t) async {
    tall(t);
    await t.pumpWidget(wrap(ItemSalesReportScreen(
        orders: orders(),
        categories: categories,
        costs: costs,
        formatAmount: money)));
    expect(find.byKey(const Key('item-sales-grand')), findsOneWidget);
  });

  testWidgets('session detail lists a split check and its footer', (t) async {
    tall(t);
    final o = dineIn();
    await t.pumpWidget(
        wrap(SessionDetailReportScreen(orders: [o], formatAmount: money)));
    expect(find.byKey(Key('check-${o.uuid}')), findsOneWidget);
    expect(find.byKey(const Key('session-detail-footer')), findsOneWidget);
    // Both tenders show.
    expect(find.text('Cash'), findsWidgets);
    expect(find.text('Card'), findsWidgets);
  });

  testWidgets('revenue centre renders its footer', (t) async {
    tall(t);
    await t.pumpWidget(
        wrap(RevenueCenterReportScreen(orders: orders(), formatAmount: money)));
    expect(find.byKey(const Key('revenue-center-footer')), findsOneWidget);
  });

  testWidgets('daily sales renders its footer', (t) async {
    tall(t);
    await t.pumpWidget(
        wrap(DailySalesReportScreen(orders: orders(), formatAmount: money)));
    expect(find.byKey(const Key('daily-sales-footer')), findsOneWidget);
  });

  testWidgets('detailed discounts lists the check discount', (t) async {
    tall(t);
    await t.pumpWidget(wrap(
        DetailedDiscountsReportScreen(orders: orders(), formatAmount: money)));
    expect(find.byKey(const Key('detailed-discounts-list')), findsOneWidget);
    expect(find.byKey(const Key('detailed-discounts-total')), findsOneWidget);
  });

  testWidgets('refunds summary says so when there are none', (t) async {
    tall(t);
    await t.pumpWidget(
        wrap(RefundsSummaryReportScreen(orders: orders(), formatAmount: money)));
    expect(find.byKey(const Key('refunds-summary-none')), findsOneWidget);
  });

  testWidgets('session summary renders and marks untracked sections', (t) async {
    tall(t);
    await t.pumpWidget(wrap(SessionSummaryReportScreen(
        orders: orders(),
        categories: categories,
        costs: costs,
        formatAmount: money)));
    expect(find.byKey(const Key('session-summary-list')), findsOneWidget);
    expect(find.text('Not tracked'), findsWidgets);
  });
}
