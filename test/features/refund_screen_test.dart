import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/orders/refund_screen.dart';

void main() {
  // Push the screen through a real route so its closing pop has somewhere to go.
  Future<Order?> openAndRefund(WidgetTester t, Order original) async {
    Order? captured;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () => Navigator.push(
              ctx,
              MaterialPageRoute<void>(
                builder: (_) => RefundScreen(
                  original: original,
                  formatAmount: (v) => v.toStringAsFixed(2),
                  onRefund: (r) => captured = r,
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('refund-reason')), 'wrong item');
    await t.pump();
    await t.tap(find.byKey(const Key('confirm-refund')));
    await t.pumpAndSettle();
    return captured;
  }

  testWidgets('a refund carries the line tax and returns money on the original tender',
      (t) async {
    final original = Order(
      deviceId: 'd',
      cashierId: 'c',
      payments: [const OrderPayment(methodId: 2, amount: 30, label: 'Card')],
    )..lines.add(OrderLine(
        productId: 1, name: 'Pizza', quantity: 2, unitPrice: 15, taxRate: 14));

    final refund = await openAndRefund(t, original);

    expect(refund, isNotNull);
    // The reversed line keeps the tax it is crediting back.
    expect(refund!.lines.single.taxRate, 14);
    expect(refund.lines.single.quantity, -2);
    // Money goes back out on the same method the sale came in on, not to cash.
    final p = refund.payments.single;
    expect(p.methodId, 2);
    expect(p.label, 'Card');
    expect(p.amount, lessThan(0));
    expect(refund.refundOfUuid, original.uuid);
  });

  testWidgets('a cash-tendered sale (no recorded payment) refunds without a tender',
      (t) async {
    final original = Order(deviceId: 'd', cashierId: 'c')
      ..lines.add(OrderLine(productId: 1, name: 'Cola', quantity: 1, unitPrice: 10));

    final refund = await openAndRefund(t, original);

    expect(refund, isNotNull);
    expect(refund!.payments, isEmpty); // server books the credit to cash
    expect(refund.lines.single.quantity, -1);
  });
}
