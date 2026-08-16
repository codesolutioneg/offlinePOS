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

/// The slip a part payment leaves behind. Its whole job is to say what this money
/// covered and what is still owed, because no other paper says either: the sale
/// receipt does not print until the tab settles.
void main() {
  test('a share prints what was paid and what is left, and is not a tax receipt', () {
    final o = table();
    final bytes = builder().buildPartialPayment(
      PartialPayment(
        order: o,
        paidNow: 150,
        stillOwed: 150,
        title: 'Share of 2',
        tenders: [OrderPayment(methodId: 1, amount: 150, label: 'Cash')],
      ),
      at: DateTime.utc(2026, 1, 2, 9, 30),
      actor: 'sara',
    );
    final s = strippedText(bytes);
    expect(s, contains('JOUMA'));
    expect(s, contains('PAYMENT'));
    expect(s, contains('NOT A TAX RECEIPT'));
    expect(s, contains('Table 5'));
    expect(s, contains('Cashier: sara'));
    expect(s, contains('Share of 2'));
    expect(s, contains('Cash'));
    expect(s, contains('PAID NOW'));
    expect(s, contains('STILL OWED'));
    // Both figures print, so neither the guest paying nor the next one has to guess.
    expect('150.00'.allMatches(s).length, greaterThanOrEqualTo(3));
  });

  test('an even share itemises nothing, because it bought a share of everything', () {
    final s = strippedText(builder().buildPartialPayment(
      PartialPayment(order: table(), paidNow: 150, stillOwed: 150),
      at: DateTime.utc(2026, 1, 2),
    ));
    expect(s, isNot(contains('Pizza')));
    expect(s, isNot(contains('Cola')));
  });

  test('a check itemises what it covered', () {
    final o = table();
    final s = strippedText(builder().buildPartialPayment(
      PartialPayment(
        order: o,
        paidNow: 50,
        stillOwed: 250,
        title: 'Guest 2',
        covered: [o.lines.last],
        tenders: [OrderPayment(methodId: 2, amount: 50, label: 'Card')],
      ),
      at: DateTime.utc(2026, 1, 2),
    ));
    expect(s, contains('Cola'));
    expect(s, isNot(contains('Pizza')));
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
      at: DateTime.utc(2026, 1, 2),
    ));
    expect(s, contains('Received'));
    expect(s, contains('200.00'));
    expect(s, contains('Change'));
    expect(s, contains('50.00'));
  });

  test('the drawer opens for the cash it took, and only when the shop asked', () {
    bool kicks(List<int> bytes) {
      for (var i = 0; i + 1 < bytes.length; i++) {
        if (bytes[i] == 0x1b && bytes[i + 1] == 0x70) return true;
      }
      return false;
    }

    final payment = PartialPayment(order: table(), paidNow: 150, stillOwed: 150);
    final at = DateTime.utc(2026, 1, 2);
    expect(kicks(builder(openDrawer: true).buildPartialPayment(payment, at: at)), isTrue);
    expect(kicks(builder().buildPartialPayment(payment, at: at)), isFalse);
  });

  test('a shop that hides the tender breakdown still gets the two figures', () {
    final s = strippedText(builder(showPayment: false).buildPartialPayment(
      PartialPayment(
        order: table(),
        paidNow: 150,
        stillOwed: 150,
        tenders: [OrderPayment(methodId: 1, amount: 150, label: 'Cash')],
      ),
      at: DateTime.utc(2026, 1, 2),
    ));
    expect(s, isNot(contains('Cash')));
    expect(s, contains('PAID NOW'));
    expect(s, contains('STILL OWED'));
  });
}
