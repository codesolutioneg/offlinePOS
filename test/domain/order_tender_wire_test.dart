import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/domain/order.dart';

/// What a tender says on the wire, now that the till's tenders are the shop's bank
/// and cash journals.
///
/// The booking module resolves `method_id` against `pos.payment.method`. A journal
/// id put there would browse a different table, find whatever happened to share the
/// number, and settle the money into it, so a journal tender names `journal_id` and
/// nothing else. A tender rung before this existed still names its method, because
/// that is how it was taken and how it has to book.
Order sale({required List<OrderPayment> payments}) {
  final o = Order(deviceId: 'till-1', cashierId: 'c1')
    ..lines.add(OrderLine(
        productId: 10, odooProductId: 10, name: 'Margherita', quantity: 1,
        unitPrice: 100));
  o.payments = payments;
  return o;
}

List<Map<String, dynamic>> wire(Order o) =>
    (o.toServerPayload()['payments'] as List)
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();

void main() {
  test('a journal tender names the journal and never a payment method', () {
    final tender = PaymentMethod.journal(
        journalId: 12, name: 'Bank CIB', type: 'bank');
    final o = sale(payments: [
      OrderPayment(methodId: tender.id, amount: 100, label: tender.name)
    ]);

    final sent = wire(o).single;
    expect(sent['journal_id'], 12);
    expect(sent.containsKey('method_id'), isFalse,
        reason: 'a journal id sitting in method_id would be browsed as a '
            'pos.payment.method and book the card takings into the drawer');
    expect(sent['label'], 'Bank CIB',
        reason: "the journal's own name, which is what a server without the "
            'journal field still resolves the tender by');
    expect(sent['amount'], 100);
  });

  test('a sale rung under the old ids still names its method', () {
    final o = sale(
        payments: const [OrderPayment(methodId: 2, amount: 100, label: 'Card')]);

    final sent = wire(o).single;
    expect(sent['method_id'], 2);
    expect(sent.containsKey('journal_id'), isFalse,
        reason: 'the server reads the journal off the method, live, which is '
            'exactly how this sale was always going to book');
  });

  test('an on-account tender names neither', () {
    final tender =
        PaymentMethod.journal(journalId: 12, name: 'Bank CIB', type: 'bank');
    final o = sale(payments: [
      OrderPayment(methodId: tender.id, amount: 100, label: kOnAccountLabel)
    ]);

    final sent = wire(o).single;
    expect(sent.containsKey('journal_id'), isFalse,
        reason: 'nothing was banked, so naming a journal could only invite a '
            'server to register a payment for money the guest has signed for');
    expect(sent.containsKey('method_id'), isFalse);
    expect(sent['label'], kOnAccountLabel,
        reason: 'the label is the whole statement that this is a tab');
  });

  test('a split across both id spaces keeps each tender as it was taken', () {
    final o = sale(payments: [
      const OrderPayment(methodId: 2, amount: 40, label: 'Card'),
      const OrderPayment(methodId: -11, amount: 60, label: 'Cash drawer'),
    ]);

    final sent = wire(o);
    expect(sent[0]['method_id'], 2);
    expect(sent[1]['journal_id'], 11);
  });

  test('a tender survives being written to disk and read back', () {
    final o = sale(payments: const [
      OrderPayment(methodId: -12, amount: 60, label: 'Bank CIB'),
      OrderPayment(methodId: 2, amount: 40, label: 'Card'),
    ]);

    final back = Order.fromMap(o.toMap());
    expect(back.payments.map((p) => p.methodId), [-12, 2],
        reason: 'what is held on the till is the tender as it was rung, in the '
            'space it was rung in; the translating happens on the way out');
    expect(back.payments.first.journalId, 12);
    expect(back.payments.first.isJournal, isTrue);
    expect(back.payments.last.journalId, isNull);
    expect(back.payments.last.isJournal, isFalse);
  });
}
