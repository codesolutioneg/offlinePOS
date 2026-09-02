import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';

/// Menu prices are net and the tax is charged on top of them, which is what the
/// shop's on-site till does and therefore what its guests have been paying. These
/// are the sums a cashier reads out and the server has to arrive at independently.
void main() {
  Order sale({
    double taxRate = 14,
    double quantity = 2,
    double unitPrice = 100,
    double servicePercent = 0,
    double discountPercent = 0,
    double delivery = 0,
    double tip = 0,
    List<OrderLine>? lines,
  }) =>
      Order(
        deviceId: 'till-1',
        cashierId: 'sara',
        serviceChargePercent: servicePercent,
        discountPercent: discountPercent,
        deliveryCost: delivery,
        tip: tip,
        lines: lines ??
            [
              OrderLine(
                  productId: 1,
                  name: 'Pizza',
                  quantity: quantity,
                  unitPrice: unitPrice,
                  taxRate: taxRate),
            ],
      );

  test('the tax is added on top of the menu price', () {
    final o = sale();
    expect(o.subtotal, 200);
    expect(o.taxTotal, closeTo(28, 0.0001));
    expect(o.total, closeTo(228, 0.0001));
  });

  test('an untaxed line is charged at its menu price', () {
    final o = sale(taxRate: 0);
    expect(o.taxTotal, 0);
    expect(o.total, 200);
  });

  test('each line is taxed at its own rate', () {
    final o = sale(lines: [
      OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 100, taxRate: 14),
      OrderLine(productId: 2, name: 'Bread', quantity: 1, unitPrice: 50, taxRate: 0),
    ]);
    // Only the taxed line contributes: a zero-rated category beside a taxed one is
    // exactly why the rate lives on the line and not on the sale.
    expect(o.taxTotal, closeTo(14, 0.0001));
    expect(o.total, closeTo(164, 0.0001));
  });

  test('delivery and a tip are outside the tax base', () {
    final o = sale(delivery: 30, tip: 10);
    // 200 food + 28 tax + 30 delivery + 10 tip. The delivery is exempt on the
    // shop's other till, and a tip is not a supply.
    expect(o.taxTotal, closeTo(28, 0.0001));
    expect(o.total, closeTo(268, 0.0001));
  });

  test('the service charge is taxed with the food', () {
    final o = sale(servicePercent: 12);
    // The charge travels inside the line prices, so the server taxes it there; the
    // slip has to show the same. 224 net, 31.36 tax.
    expect(o.serviceCharge, closeTo(24, 0.0001));
    expect(o.taxTotal, closeTo(31.36, 0.0001));
    expect(o.total, closeTo(255.36, 0.0001));
  });

  test('an order discount leaves the tax on the full subtotal', () {
    final o = sale(discountPercent: 25);
    // The shop's rule: the discount is its own generosity and the state's share
    // is owed on what was sold. 150 of food after the discount, but still the
    // full 28 of tax on the 200 that was sold.
    expect(o.taxTotal, closeTo(28, 0.0001));
    expect(o.total, closeTo(178, 0.0001));
  });

  test('a line discount reduces the tax on that line only', () {
    final o = sale(lines: [
      OrderLine(
          productId: 1,
          name: 'Pizza',
          quantity: 1,
          unitPrice: 100,
          taxRate: 14,
          discountPercent: 50),
      OrderLine(productId: 2, name: 'Cola', quantity: 1, unitPrice: 20, taxRate: 14),
    ]);
    expect(o.subtotal, closeTo(70, 0.0001));
    expect(o.taxTotal, closeTo(9.8, 0.0001));
    expect(o.total, closeTo(79.8, 0.0001));
  });

  group('what the server is handed', () {
    test('line prices travel net, so the server adds the tax itself', () {
      final o = sale();
      final sent = o.toServerPayload();
      final line = (sent['lines'] as List).single as Map<String, dynamic>;
      // Net, not grossed up: the server applies the product's own tax to this.
      expect(line['unit_price'], closeTo(100, 0.0001));
      expect(sent['amount_total'], closeTo(228, 0.0001));
    });

    test('the stated total is the taxed one the customer paid', () {
      final o = sale(servicePercent: 12, discountPercent: 10, delivery: 30, tip: 5);
      final sent = o.toServerPayload();
      expect(sent['amount_total'], closeTo(o.total, 0.0001));
      // The folded price is shaped so the server's own tax arithmetic lands on
      // the same figure the guest paid: price x (1 + r) has to equal the
      // discounted food plus the UNdiscounted tax, so the fold on a taxed line
      // is (f + r) / (1 + r) rather than a flat f.
      final line = (sent['lines'] as List).single as Map<String, dynamic>;
      expect(line['unit_price'],
          closeTo(100 * 1.12 * (0.9 + 0.14) / 1.14, 0.0001));
      // And the server's multiplication indeed reproduces the till's food+tax.
      final unit = line['unit_price'] as double;
      expect(unit * 2 * 1.14,
          closeTo(o.subtotal * 0.9 * 1.12 + o.taxTotal, 0.0001));
    });

    test('a balance is what is still owed on the taxed total', () {
      final o = sale();
      o.payments = [const OrderPayment(methodId: 1, amount: 100)];
      expect(o.balance, closeTo(128, 0.0001));
    });
  });
}
