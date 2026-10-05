import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/printing/receipt_builder.dart';
import 'package:offline_pos/domain/order.dart';

import 'strip_escpos.dart';

ReceiptBuilder builder({bool openDrawer = false, bool showPayment = true}) =>
    ReceiptBuilder(
      shopName: 'JOUMA',
      openDrawer: openDrawer,
      showPayment: showPayment,
      formatAmount: (v) => v.toStringAsFixed(2),
      paymentLabels: const {2: 'Visa'},
    );

Order table() => Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      type: OrderType.dineIn,
      tableLabel: '5',
      lines: [
        OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 250),
        OrderLine(productId: 2, name: 'Cola', quantity: 1, unitPrice: 50),
      ],
    );

/// The slip a part payment leaves behind. It is the sale receipt's own layout, so
/// a guest at a split table gets the same paper as a whole bill, with the due
/// figure being their share and the table's remaining balance under it.
void main() {
  test('a share prints in the sale receipt layout, not a separate payment slip', () {
    final o = table();
    final share = strippedText(builder().buildPartialPayment(
      PartialPayment(
        order: o,
        paidNow: 150,
        stillOwed: 150,
        tenders: [OrderPayment(methodId: 1, amount: 150, label: 'Cash')],
      ),
    ));
    final receipt = strippedText(builder().build(o));
    for (final common in ['JOUMA', 'Table 5', 'DINE IN', 'ORDER', 'Server: sara']) {
      expect(receipt, contains(common));
      expect(share, contains(common));
    }
    // No "Share of N" heading: the guest's figure is the due line itself.
    expect(share, isNot(contains('Share of')));
    expect(share, contains('Cash'));
    expect(share, contains('TOTAL DUE: 150.00'));
    expect(share, contains('Balance remaining'));
    expect(share, isNot(contains('PAYMENT')));
    expect(share, isNot(contains('NOT A TAX RECEIPT')));
    expect(share, isNot(contains('PAID NOW')));
    expect(share, isNot(contains('STILL OWED')));
  });

  test('an even share lists the whole table and states the bill total', () {
    final s = strippedText(builder().buildPartialPayment(
      PartialPayment(order: table(), paidNow: 100, stillOwed: 200),
    ));
    expect(s, contains('Pizza'));
    expect(s, contains('Cola'));
    expect(s, contains('Bill total'));
    expect(s, contains('300.00'));
    expect(s, contains('TOTAL DUE: 100.00'));
  });

  test('a check itemises only what it covered', () {
    final o = table();
    final s = strippedText(builder().buildPartialPayment(
      PartialPayment(
        order: o,
        paidNow: 50,
        stillOwed: 250,
        covered: [o.lines.last],
        tenders: [OrderPayment(methodId: 2, amount: 50, label: 'Card')],
      ),
    ));
    expect(s, contains('Cola'));
    expect(s, isNot(contains('Pizza')));
    expect(s, isNot(contains('Bill total')));
    expect(s, contains('TOTAL DUE: 50.00'));
    // The shop's own name for the tender wins over the one it was rung with.
    expect(s, contains('Visa'));
    expect(s, contains('250.00'));
  });

  test('cash handed over prints the change, the way a sale receipt does', () {
    final s = strippedText(builder().buildPartialPayment(
      PartialPayment(
        order: table(),
        paidNow: 150,
        stillOwed: 150,
        cashReceived: 200,
        tenders: [OrderPayment(methodId: 1, amount: 150, label: 'Cash')],
      ),
    ));
    expect(s, contains('Received'));
    expect(s, contains('200.00'));
    expect(s, contains('Change'));
    expect(s, contains('50.00'));
  });

  test('the last share owes nothing, so no balance line prints', () {
    final s = strippedText(builder().buildPartialPayment(
      PartialPayment(order: table(), paidNow: 150, stillOwed: 0),
    ));
    expect(s, isNot(contains('Balance remaining')));
  });

  test('the drawer opens for the cash it took, and only when the shop asked', () {
    bool kicks(List<int> bytes) {
      for (var i = 0; i + 1 < bytes.length; i++) {
        if (bytes[i] == 0x1b && bytes[i + 1] == 0x70) return true;
      }
      return false;
    }

    final payment = PartialPayment(order: table(), paidNow: 150, stillOwed: 150);
    expect(kicks(builder(openDrawer: true).buildPartialPayment(payment)), isTrue);
    expect(kicks(builder().buildPartialPayment(payment)), isFalse);
  });

  test('a shop that hides the tender breakdown still gets its share and balance', () {
    final s = strippedText(builder(showPayment: false).buildPartialPayment(
      PartialPayment(
        order: table(),
        paidNow: 150,
        stillOwed: 150,
        tenders: [OrderPayment(methodId: 1, amount: 150, label: 'Cash')],
      ),
    ));
    expect(s, isNot(contains('Cash')));
    expect(s, contains('TOTAL DUE: 150.00'));
    expect(s, contains('Balance remaining'));
  });
}
