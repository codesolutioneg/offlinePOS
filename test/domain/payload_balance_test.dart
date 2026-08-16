import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/domain/payload_balance.dart';

/// The one thing a sale payload must never get wrong.
///
/// The module totals the sale from the lines it is handed and settles it from the
/// payments it is handed. If those disagree the sale books for the wrong money or
/// does not book at all, and either way the takings are missing from the books. So
/// every shape a bill can take is walked here and both sides are held to each
/// other. A charge that reaches the payments and not the lines has to turn one of
/// these red.
void main() {
  Order sale({
    double delivery = 0,
    double tip = 0,
    double service = 0,
    double orderDiscount = 0,
    double lineDiscount = 0,
    bool modifierWithProduct = false,
    bool modifierWithoutProduct = false,
  }) {
    final o = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      type: delivery > 0 ? OrderType.delivery : OrderType.dineIn,
      deliveryCost: delivery,
      tip: tip,
      serviceChargePercent: service,
      discountPercent: orderDiscount,
    );
    o.lines.add(OrderLine(
      productId: 10,
      odooProductId: 10,
      name: 'Koshari',
      quantity: 2,
      unitPrice: 62.5,
      discountPercent: lineDiscount,
      modifiers: [
        if (modifierWithProduct)
          OrderModifier(
              modifierId: 1,
              productId: 88,
              name: 'Extra chicken',
              quantity: 1,
              unitPrice: 30),
        if (modifierWithoutProduct)
          OrderModifier(
              modifierId: 2, name: 'Extra spicy', quantity: 1, unitPrice: 7.5),
      ],
    ));
    o.lines.add(OrderLine(
      productId: 11,
      odooProductId: 11,
      name: 'Lemonade',
      quantity: 1,
      unitPrice: 33.33,
    ));
    return o;
  }

  /// Settle [o] the way the till does: the whole balance on one tender.
  void payInFull(Order o) {
    o.payments = [OrderPayment(methodId: 1, amount: o.total, label: 'Cash')];
    o.state = OrderState.paid;
  }

  /// Settle [o] across two tenders, the way a part-cash part-card bill goes.
  void paySplit(Order o) {
    final half = (o.total / 2 * 100).roundToDouble() / 100;
    o.payments = [
      OrderPayment(methodId: 1, amount: half, label: 'Cash'),
      // The last share carries the remainder, so rounding never loses a piastre.
      OrderPayment(methodId: 2, amount: o.total - half, label: 'Card'),
    ];
    o.state = OrderState.paid;
  }

  tearDown(() => DiscountBooking.productId = null);

  test('every shape of bill declares the money it was paid', () {
    for (final delivery in [0.0, 25.0]) {
      for (final tip in [0.0, 10.0]) {
        for (final service in [0.0, 12.0]) {
          for (final orderDiscount in [0.0, 25.0]) {
            for (final lineDiscount in [0.0, 10.0]) {
              for (final discountProduct in [null, 900]) {
                for (final split in [false, true]) {
                  DiscountBooking.productId = discountProduct;
                  final o = sale(
                    delivery: delivery,
                    tip: tip,
                    service: service,
                    orderDiscount: orderDiscount,
                    lineDiscount: lineDiscount,
                    modifierWithProduct: true,
                    modifierWithoutProduct: true,
                  );
                  split ? paySplit(o) : payInFull(o);
                  final p = o.toServerPayload();
                  final where = 'delivery=$delivery tip=$tip service=$service '
                      'orderDiscount=$orderDiscount lineDiscount=$lineDiscount '
                      'discountProduct=$discountProduct split=$split';
                  expect(payloadBalances(p), isTrue,
                      reason: 'payments must equal the lines plus delivery and '
                          'tip ($where): ${payloadImbalanceReason(p)}');
                  // And what the two sides agree on is what the till charged, not
                  // some other figure they happen to share.
                  expect(payloadDeclaredTotal(p), closeTo(o.total, 0.01),
                      reason: where);
                  expect(p['amount_total'], closeTo(o.total, 0.001), reason: where);
                }
              }
            }
          }
        }
      }
    }
  });

  test('a delivery charge and a tip reach the server to be priced', () {
    final o = sale(delivery: 25, tip: 10);
    payInFull(o);
    final p = o.toServerPayload();
    // They travel as their own fields, which is what the module prices into its
    // own total as service lines. Removing either without removing it from the
    // payments is how a sale stops adding up.
    expect(p['delivery_cost'], 25);
    expect(p['tip'], 10);
    expect(payloadPricedExtras(p), 35);
    expect(payloadLinesTotal(p), closeTo(o.subtotal, 0.01),
        reason: 'the lines are the food; the two charges are not in them');
  });

  test('a priced choice with no product of its own is inside its parent line', () {
    final o = sale(modifierWithoutProduct: true);
    payInFull(o);
    final p = o.toServerPayload();
    final line = ((p['lines'] as List).first as Map).cast<String, dynamic>();
    // 62.50 for the dish plus 7.50 for the choice: the server books one line at
    // 70, because a choice with no product is a line it cannot create.
    expect(line['unit_price'], closeTo(70, 0.001));
    final mod = ((line['modifiers'] as List).first as Map).cast<String, dynamic>();
    expect(mod['unit_price'], 0.0,
        reason: 'it is already in the parent; charging it again would double it');
    expect(mod['name'], 'Extra spicy', reason: 'the choice still reads on the document');
    expect(payloadBalances(p), isTrue);
  });

  test('a choice backed by a product stays its own line', () {
    final o = sale(modifierWithProduct: true);
    payInFull(o);
    final p = o.toServerPayload();
    final line = ((p['lines'] as List).first as Map).cast<String, dynamic>();
    expect(line['unit_price'], closeTo(62.5, 0.001),
        reason: 'it moves stock, so the server needs it as a line of its own');
    final mod = ((line['modifiers'] as List).first as Map).cast<String, dynamic>();
    expect(mod['unit_price'], closeTo(30, 0.001));
    expect(payloadBalances(p), isTrue);
  });

  test('a sale with no payments is balanced: the server books its own total', () {
    final o = sale(delivery: 25, tip: 10);
    o.state = OrderState.paid;
    final p = o.toServerPayload();
    expect(p['payments'], isEmpty);
    expect(payloadBalances(p), isTrue);
  });

  test('a refund declares the money it hands back', () {
    final original = sale(service: 12);
    payInFull(original);
    // What the refund screen builds: negative lines, and the tenders reversed in
    // the proportion they were taken in.
    final refund = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      serviceChargePercent: original.serviceChargePercent,
      lines: [
        for (final l in original.lines)
          OrderLine(
            productId: l.productId,
            odooProductId: l.odooProductId,
            name: l.name,
            quantity: -l.quantity,
            unitPrice: l.unitPrice,
            modifiers: l.modifiers,
          ),
      ],
    )..refundOfUuid = original.uuid;
    refund.payments = [
      OrderPayment(methodId: 1, amount: refund.total, label: 'Cash')
    ];
    final p = refund.toServerPayload();
    expect(payloadTendered(p), lessThan(0), reason: 'money going back out');
    expect(payloadBalances(p), isTrue, reason: payloadImbalanceReason(p) ?? '');
  });

  test('a charge on the payments and not on the lines is caught', () {
    final o = sale();
    payInFull(o);
    final p = o.toServerPayload();
    // Exactly the shape of the bug this exists to stop: a charge is tendered and
    // the lines never learn about it.
    (p['payments'] as List).add({'method_id': 1, 'amount': 40.0, 'label': 'Cash'});
    expect(payloadBalances(p), isFalse);
    expect(payloadImbalanceReason(p), contains('does not add up'));
  });

  test('a piastre of rounding is not a broken payload', () {
    final o = sale();
    payInFull(o);
    final p = o.toServerPayload();
    ((p['payments'] as List).first as Map)['amount'] = o.total + 0.009;
    expect(payloadBalances(p), isTrue);
  });
}
