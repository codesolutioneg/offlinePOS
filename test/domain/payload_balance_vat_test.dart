import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/domain/payload_balance.dart';

/// The balance check has to know that the server adds the tax.
///
/// Prices travel net, so the money tendered is always more than the lines come to.
/// A check that did not account for that would read the difference as a broken
/// payload and park every taxed sale on the till instead of sending it, which is
/// the one failure mode worse than sending a wrong number.
void main() {
  Order sale({
    double taxRate = 14,
    double delivery = 0,
    double tip = 0,
    double service = 0,
    double orderDiscount = 0,
    bool modifierWithProduct = false,
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
      taxRate: taxRate,
      modifiers: [
        if (modifierWithProduct)
          OrderModifier(
              modifierId: 1,
              productId: 88,
              name: 'Extra chicken',
              quantity: 1,
              unitPrice: 30),
      ],
    ));
    return o;
  }

  Map<String, dynamic> paid(Order o) {
    o.payments = [OrderPayment(methodId: 1, amount: o.total, label: 'Cash')];
    o.state = OrderState.paid;
    return o.toServerPayload();
  }

  test('a taxed sale balances', () {
    final payload = paid(sale());
    expect(payloadTaxTotal(payload), closeTo(17.5, 0.0001));
    expect(payloadImbalanceReason(payload), isNull);
  });

  test('an untaxed sale still balances', () {
    final payload = paid(sale(taxRate: 0));
    expect(payloadTaxTotal(payload), 0);
    expect(payloadImbalanceReason(payload), isNull);
  });

  test('delivery and tip are tendered but not taxed', () {
    final payload = paid(sale(delivery: 30, tip: 10));
    expect(payloadTaxTotal(payload), closeTo(17.5, 0.0001));
    expect(payloadImbalanceReason(payload), isNull);
  });

  test('a discounted, serviced, modified bill still balances', () {
    final payload =
        paid(sale(service: 12, orderDiscount: 10, modifierWithProduct: true));
    expect(payloadImbalanceReason(payload), isNull);
  });

  test('with a discount product the declared tax equals the tax the till charged',
      () {
    // Folded prices can state the right TOTAL but never the right tax split:
    // the server taxes the price it is sent, and no single price carries both
    // the discounted food and the undiscounted tax as separate figures. The
    // discount product mode is the one that represents the shop's rule
    // faithfully: full prices, full tax, and the discount as its own untaxed
    // negative line.
    DiscountBooking.productId = 999;
    addTearDown(() => DiscountBooking.productId = null);
    final o = sale(service: 12, orderDiscount: 10, modifierWithProduct: true);
    final payload = paid(o);
    expect(payloadTaxTotal(payload), closeTo(o.taxTotal, 0.01));
    expect(payloadImbalanceReason(payload), isNull);
  });

  test('folded prices still balance to the taxed total the guest paid', () {
    final o = sale(service: 12, orderDiscount: 10, modifierWithProduct: true);
    final payload = paid(o);
    // No discount product: the fold reshapes each taxed price so the server's
    // own multiplication lands on the till's figure, tax and all.
    expect(payloadImbalanceReason(payload), isNull);
  });

  test('a payment that misses the tax is called out, naming it', () {
    final o = sale();
    // A till that tendered only the net: the gap is exactly the tax.
    o.payments = [OrderPayment(methodId: 1, amount: o.subtotal, label: 'Cash')];
    final reason = payloadImbalanceReason(o.toServerPayload());
    expect(reason, isNotNull);
    expect(reason, contains('plus tax'));
    expect(reason, contains('17.50'));
  });
}
