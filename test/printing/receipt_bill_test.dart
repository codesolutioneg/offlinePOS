import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/printing/receipt_builder.dart';
import 'package:offline_pos/domain/order.dart';

import 'strip_escpos.dart';

/// The pre-payment check a waiter carries to the table.
///
/// Everything asserted here is about what a bill must NOT say: it is handed over
/// before any money moves, so a tender line, a change line or a drawer kick on it
/// would either open the till for nothing or read as proof of a payment that has not
/// happened yet.
void main() {
  ReceiptBuilder builder({bool openDrawer = false}) => ReceiptBuilder(
        shopName: 'JOUMA',
        taxId: 'TAX 123',
        footer: 'Thank you',
        openDrawer: openDrawer,
        formatAmount: (v) => v.toStringAsFixed(2),
      );

  Order table() => Order(
        deviceId: 'till-1',
        cashierId: 'sara',
        type: OrderType.dineIn,
        tableLabel: 'T4',
        guestCount: 2,
        lines: [
          OrderLine(productId: 1, name: 'Pizza', quantity: 2, unitPrice: 250, modifiers: [
            OrderModifier(modifierId: 1, name: 'Extra Cheese', quantity: 1, unitPrice: 7),
          ]),
          OrderLine(productId: 2, name: 'Water', quantity: 3, unitPrice: 10),
        ],
      );

  String bill(Order o, {bool openDrawer = false}) =>
      strippedText(builder(openDrawer: openDrawer).buildBill(o));

  test('is titled BILL and says it is not a tax receipt', () {
    final s = bill(table());
    expect(s, contains('BILL'));
    expect(s, contains('NOT A TAX RECEIPT'));
  });

  test('carries the same lines and total as the sale receipt', () {
    final o = table();
    final s = bill(o);
    expect(s, contains('Pizza'));
    expect(s, contains('+ Extra Cheese'));
    expect(s, contains('Water'));
    expect(s, contains('T4'));
    expect(s, contains('sara'));
    // 2 x (250 + 7) + 3 x 10
    expect(o.total, 544);
    expect(s, contains('544.00'));
  });

  test('prints no tender, received or change rows', () {
    final o = table()
      ..payments.add(const OrderPayment(methodId: 1, label: 'Visa', amount: 544))
      ..cashReceived = 600;
    final s = bill(o);
    expect(s, isNot(contains('Visa')));
    expect(s, isNot(contains('Received')));
    expect(s, isNot(contains('Change')));
    expect(s, isNot(contains('600.00')));
  });

  test('never kicks the drawer, even when the builder is set to', () {
    // ESC p 0 t1 t2. A bill is not a sale, so the till stays shut.
    const kick = [0x1b, 0x70, 0x00, 0x19, 0xfa];
    final bytes = builder(openDrawer: true).buildBill(table());
    expect(_contains(bytes, kick), isFalse);
    // The same builder does kick on the real receipt, so the flag is honoured and it
    // is the bill that suppresses it.
    expect(_contains(builder(openDrawer: true).build(table()), kick), isTrue);
  });

  test('a part-paid tab states what is still owed, not the whole total again', () {
    final o = table()..payments.add(const OrderPayment(methodId: 1, amount: 200));
    final s = bill(o);
    expect(s, contains('Already paid'));
    expect(s, contains('-200.00'));
    expect(s, contains('BALANCE DUE'));
    expect(s, contains('344.00'));
  });

  test('an unpaid table shows no balance section', () {
    final s = bill(table());
    expect(s, isNot(contains('Already paid')));
    expect(s, isNot(contains('BALANCE DUE')));
  });

  test('the sale receipt is unchanged by the bill path', () {
    final o = table()
      ..payments.add(const OrderPayment(methodId: 1, label: 'Visa', amount: 544))
      ..cashReceived = 600;
    final s = strippedText(builder().build(o));
    expect(s, contains('Visa'));
    expect(s, contains('Change'));
    expect(s, isNot(contains('BILL')));
    expect(s, isNot(contains('NOT A TAX RECEIPT')));
  });

  test('building a bill leaves the order and its lines untouched', () {
    final o = table();
    final before = o.toMap();
    final lineCount = o.lines.length;
    builder().buildBill(o);
    expect(o.toMap(), before);
    expect(o.lines.length, lineCount);
    expect(o.state, OrderState.draft);
    expect(o.payments, isEmpty);
  });
}

bool _contains(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var hit = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return true;
  }
  return false;
}
