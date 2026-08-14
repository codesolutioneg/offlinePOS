import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/orders/refund_screen.dart';

void main() {
  // Pushed through a real route so the screen's closing pop has somewhere to go.
  Future<Order?> refundAll(WidgetTester t, Order original) async {
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
                  actingCashierId: 'bob',
                  deviceId: 'till-2',
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
    await t.enterText(find.byKey(const Key('refund-reason')), 'sent back');
    await t.pump();
    await t.tap(find.byKey(const Key('confirm-refund')));
    await t.pumpAndSettle();
    return captured;
  }

  Order sale({double servicePercent = 12, int units = 2}) => Order(
        deviceId: 'd',
        cashierId: 'c',
        serviceChargePercent: servicePercent,
        payments: [
          OrderPayment(
              methodId: 2, amount: 100.0 * units * (1 + servicePercent / 100), label: 'Card'),
        ],
        lines: [
          OrderLine(
              productId: 1, name: 'Pizza', quantity: units.toDouble(), unitPrice: 100),
        ],
      );

  testWidgets('a full refund gives back the service the bill charged', (t) async {
    final original = sale(); // 200 food + 24 service = 224
    final refund = await refundAll(t, original);

    expect(refund!.serviceChargePercent, 12);
    expect(refund.total, closeTo(-224, 0.0001));
    // The money out on the original tender covers the service too, not the food alone.
    expect(refund.payments.single.amount, closeTo(-224, 0.0001));
  });

  testWidgets('a part refund returns the service on the returned units only', (t) async {
    final original = sale(); // 2 units
    Order? captured;
    await t.pumpWidget(MaterialApp(
      home: RefundScreen(
        original: original,
        formatAmount: (v) => v.toStringAsFixed(2),
        actingCashierId: 'bob',
        deviceId: 'till-2',
        onRefund: (r) => captured = r,
      ),
    ));
    // Step one unit off the two sold, then refund.
    await t.tap(find.byIcon(Icons.remove_circle_outline));
    await t.pump();
    await t.enterText(find.byKey(const Key('refund-reason')), 'one back');
    await t.pump();
    await t.tap(find.byKey(const Key('confirm-refund')));
    await t.pump();

    expect(captured!.lines.single.quantity, -1);
    expect(captured!.total, closeTo(-112, 0.0001));
  });

  testWidgets('a bill with no service charge refunds exactly as before', (t) async {
    final refund = await refundAll(t, sale(servicePercent: 0));
    expect(refund!.serviceChargePercent, 0);
    expect(refund.total, closeTo(-200, 0.0001));
  });
}
