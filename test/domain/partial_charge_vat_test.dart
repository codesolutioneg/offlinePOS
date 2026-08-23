import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';

/// Charging part of a bill has to charge the tax on that part.
///
/// A split check, a picked selection and a refund all take some of the lines and
/// ask for (or hand back) money. Each used to work the figure out for itself, and
/// each was one edit away from being the path that forgot the service charge or the
/// tax and quoted a guest the net. They all go through [Order.chargeFor] now, so
/// these are the sums every one of them produces.
void main() {
  Order bill({double taxRate = 14, double service = 0, double discount = 0}) {
    final o = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      serviceChargePercent: service,
      discountPercent: discount,
    );
    o.lines.addAll([
      OrderLine(
          productId: 1, name: 'Pizza', quantity: 2, unitPrice: 100, taxRate: taxRate),
      OrderLine(
          productId: 2, name: 'Cola', quantity: 1, unitPrice: 20, taxRate: taxRate),
    ]);
    return o;
  }

  test('one line of the bill is charged with its tax', () {
    final o = bill();
    expect(o.chargeFor([o.lines.last]), closeTo(22.8, 0.0001));
  });

  test('the parts add up to the whole', () {
    final o = bill(service: 12, discount: 10);
    final parts = o.lines.map((l) => o.chargeFor([l])).reduce((a, b) => a + b);
    expect(parts, closeTo(o.total, 0.0001));
  });

  test('a part quantity is charged per unit, tax and all', () {
    final o = bill();
    // One of the two pizzas: 100 net, 14 tax.
    final one = o.chargeFor([o.lines.first], quantityOf: (_) => 1);
    expect(one, closeTo(114, 0.0001));
  });

  test('an untaxed bill charges the net, as it always did', () {
    final o = bill(taxRate: 0, service: 12);
    expect(o.chargeFor(o.lines), closeTo(o.subtotal * 1.12, 0.0001));
    expect(o.chargeFor(o.lines), closeTo(o.total, 0.0001));
  });

  test('the discount and the service both reach a part charge', () {
    final o = bill(service: 12, discount: 10);
    // 20 -> 18 after the discount -> 20.16 with service -> 22.98 with tax.
    expect(o.chargeFor([o.lines.last]), closeTo(22.9824, 0.0001));
  });

  test('a zero-quantity line is worth nothing', () {
    final o = bill();
    expect(o.chargeFor([o.lines.first], quantityOf: (_) => 0), 0);
  });
}
