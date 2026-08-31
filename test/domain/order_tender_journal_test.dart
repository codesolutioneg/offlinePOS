import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';

/// Which journal a tender says it landed in.
///
/// The journal is what a manager picks on the till and what decides the drawer or
/// bank account the money went into. Naming it on the wire means the server books
/// where the till said, rather than resolving the payment method a second time and
/// possibly disagreeing about it.
void main() {
  test('a tender carries its journal onto the wire', () {
    const tender = OrderPayment(
      methodId: 4,
      journalId: 90,
      amount: 140.0,
      label: 'Card',
    );
    final wire = tender.toMap();
    expect(wire['journal_id'], 90);
    // The method still travels. A shop running an older module resolves the tender
    // exactly as it did before, so a till can be updated ahead of its server.
    expect(wire['method_id'], 4);
    expect(wire['amount'], 140.0);
  });

  test('a tender with no journal says nothing rather than saying null', () {
    const tender = OrderPayment(methodId: 4, amount: 10.0, label: 'Cash');
    final wire = tender.toMap();
    expect(wire.containsKey('journal_id'), isFalse,
        reason: 'the server falls back to the method, which is what it always did');
    expect(wire['method_id'], 4);
  });

  test('a tender survives being saved and read back', () {
    const tender = OrderPayment(
      methodId: 4,
      journalId: 90,
      amount: 140.0,
      label: 'Card',
    );
    final back = OrderPayment.fromMap(tender.toMap());
    expect(back.journalId, 90);
    expect(back.methodId, 4);
    expect(back.amount, 140.0);
    expect(back.label, 'Card');
  });

  test('a tender rung before journals existed still reads back', () {
    // Orders sitting in the outbox from an older build have no journal on them,
    // and they still have to book when the till is updated under them.
    final back = OrderPayment.fromMap(
        {'method_id': 4, 'amount': 10.0, 'label': 'Cash'});
    expect(back.journalId, isNull);
    expect(back.methodId, 4);
  });
}
