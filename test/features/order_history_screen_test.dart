import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/orders/order_history_screen.dart';

void main() {
  testWidgets('lists history tiles for each order', (tester) async {
    final orders = [
      Order(
        deviceId: 'till-1',
        cashierId: 'sara',
        createdAt: DateTime.utc(2026, 8, 6, 12, 30),
        state: OrderState.synced,
        lines: [
          OrderLine(productId: 10, name: 'Margherita', quantity: 1, unitPrice: 250),
        ],
        payments: const [OrderPayment(methodId: 1, amount: 250, label: 'Cash')],
      ),
      Order(
        deviceId: 'till-1',
        cashierId: 'sara',
        createdAt: DateTime.utc(2026, 8, 6, 12, 0),
        state: OrderState.paid,
        lines: [
          OrderLine(productId: 11, name: 'Water', quantity: 2, unitPrice: 10),
        ],
        payments: const [OrderPayment(methodId: 2, amount: 20, label: 'Card')],
      ),
    ];

    await tester.pumpWidget(MaterialApp(
      home: OrderHistoryScreen(
        orders: orders,
        formatAmount: (v) => v.toStringAsFixed(2),
        onReprint: (_) async {},
      ),
    ));

    for (final order in orders) {
      expect(find.byKey(Key('history-${order.uuid}')), findsOneWidget);
    }
  });

  testWidgets('shows an empty state instead of a blank list with no orders',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: OrderHistoryScreen(
        orders: const [],
        formatAmount: (v) => v.toStringAsFixed(2),
        onReprint: (_) async {},
      ),
    ));

    expect(find.text('No orders yet'), findsOneWidget);
  });

  /// A completed sale in [state], with one line, to open the detail view on.
  Order sale(OrderState state, {String? refundOf}) => Order(
        deviceId: 'till-1',
        cashierId: 'sara',
        state: state,
        lines: [OrderLine(productId: 10, name: 'Pizza', quantity: 1, unitPrice: 250)],
        payments: const [OrderPayment(methodId: 1, amount: 250, label: 'Cash')],
        refundOfUuid: refundOf,
      );

  Future<void> openDetail(WidgetTester tester, Order order,
      {bool withEdit = true}) async {
    await tester.pumpWidget(MaterialApp(
      home: OrderDetailScreen(
        order: order,
        formatAmount: (v) => v.toStringAsFixed(2),
        onReprint: (_) async {},
        onRefund: (_) async {},
        onEdit: withEdit ? (_) async {} : null,
      ),
    ));
  }

  testWidgets('a paid sale that has not synced can be edited or cancelled',
      (tester) async {
    final order = sale(OrderState.paid);
    await openDetail(tester, order);

    expect(find.byKey(Key('edit-${order.uuid}')), findsOneWidget);
    expect(find.byKey(Key('cancel-sale-${order.uuid}')), findsOneWidget);
    // The partial route stays, since a correction is not the only answer.
    expect(find.byKey(Key('refund-${order.uuid}')), findsOneWidget);
  });

  testWidgets('a synced sale offers neither, because the server already has it',
      (tester) async {
    final order = sale(OrderState.synced);
    await openDetail(tester, order);

    expect(find.byKey(Key('edit-${order.uuid}')), findsNothing);
    expect(find.byKey(Key('cancel-sale-${order.uuid}')), findsNothing);
    // A refund is still the answer there, so it is still offered.
    expect(find.byKey(Key('refund-${order.uuid}')), findsOneWidget);
  });

  testWidgets('a refund is never edited back into the cart', (tester) async {
    final order = sale(OrderState.paid, refundOf: 'the-original');
    await openDetail(tester, order);

    expect(find.byKey(Key('edit-${order.uuid}')), findsNothing);
    expect(find.byKey(Key('cancel-sale-${order.uuid}')), findsNothing);
  });

  testWidgets('a till with no way to edit shows no edit button', (tester) async {
    final order = sale(OrderState.paid);
    await openDetail(tester, order, withEdit: false);

    expect(find.byKey(Key('edit-${order.uuid}')), findsNothing);
  });

  testWidgets('cancelling a sale confirms first, then goes through the refund flow',
      (tester) async {
    final order = sale(OrderState.paid);
    final refunded = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: OrderDetailScreen(
        order: order,
        formatAmount: (v) => v.toStringAsFixed(2),
        onReprint: (_) async {},
        onRefund: (o) async => refunded.add(o.uuid),
        onEdit: (_) async {},
      ),
    ));

    await tester.tap(find.byKey(Key('cancel-sale-${order.uuid}')));
    await tester.pumpAndSettle();
    // Nothing has happened yet: the sale stands until the cashier says so.
    expect(refunded, isEmpty);

    await tester.tap(find.byKey(const Key('cancel-sale-ok')));
    await tester.pumpAndSettle();

    expect(refunded, [order.uuid]);
  });

  testWidgets('backing out of the confirmation leaves the sale alone',
      (tester) async {
    final order = sale(OrderState.paid);
    final refunded = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: OrderDetailScreen(
        order: order,
        formatAmount: (v) => v.toStringAsFixed(2),
        onReprint: (_) async {},
        onRefund: (o) async => refunded.add(o.uuid),
        onEdit: (_) async {},
      ),
    ));

    await tester.tap(find.byKey(Key('cancel-sale-${order.uuid}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep the sale'));
    await tester.pumpAndSettle();

    expect(refunded, isEmpty);
  });
}
