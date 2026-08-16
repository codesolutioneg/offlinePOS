import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';

Order bill({
  double servicePercent = 12,
  double discountPercent = 0,
  double deliveryCost = 0,
  double tip = 0,
  double taxRate = 0,
}) =>
    Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      serviceChargePercent: servicePercent,
      discountPercent: discountPercent,
      deliveryCost: deliveryCost,
      tip: tip,
      lines: [
        OrderLine(
            productId: 1, name: 'Pizza', quantity: 2, unitPrice: 100, taxRate: taxRate),
      ],
    );

void main() {
  test('the charge is a percentage of the food and lands in the total', () {
    final o = bill();
    expect(o.subtotal, 200);
    expect(o.serviceCharge, 24);
    expect(o.total, 224);
  });

  test('it is charged on the discounted food, not the gross', () {
    // 200 less 10% = 180 of food, then 12% service = 21.6.
    final o = bill(discountPercent: 10);
    expect(o.serviceChargeBase, 180);
    expect(o.serviceCharge, closeTo(21.6, 0.0001));
    expect(o.total, closeTo(201.6, 0.0001));
  });

  test('delivery and a tip stay outside it: neither is table service', () {
    final o = bill(deliveryCost: 30, tip: 10);
    expect(o.serviceCharge, 24);
    expect(o.total, 264); // 200 food + 24 service + 30 delivery + 10 tip
  });

  test('a bill with no charge stamped on it prices exactly as before', () {
    final o = bill(servicePercent: 0, deliveryCost: 30, tip: 10);
    expect(o.serviceChargeFactor, 1);
    expect(o.total, 240);
  });

  test('the stamped percentage survives a serialise/restore cycle', () {
    final o = bill(servicePercent: 12.5);
    final restored = Order.fromMap(o.toMap());
    expect(restored.serviceChargePercent, 12.5);
    expect(restored.total, o.total);
  });

  test('an order stored before the charge existed reads as no charge', () {
    final legacy = bill().toMap()..remove('service_charge_percent');
    expect(Order.fromMap(legacy).serviceChargePercent, 0);
  });

  test('the balance owed includes the service charge', () {
    final o = bill()
      ..payments = [const OrderPayment(methodId: 1, amount: 100, label: 'Cash')];
    expect(o.balance, 124);
  });

  test('the wire folds the charge into line prices and sends no new field', () {
    // The module books totals from line prices, so the charge has to be inside them:
    // it must never travel as a field the module does not read.
    final o = bill();
    final sent = o.toServerPayload();
    expect(sent.containsKey('service_charge_percent'), isFalse);
    final line = (sent['lines'] as List).single as Map;
    expect(line['unit_price'], closeTo(112, 0.0001));
    final booked =
        (line['quantity'] as num).toDouble() * (line['unit_price'] as num).toDouble();
    expect(booked, closeTo(o.subtotal + o.serviceCharge, 0.0001));
  });

  test('the wire folds a discount and the charge together, once each', () {
    // 100 less 10% order discount, then 12% service: 100 * 0.9 * 1.12.
    final o = bill(discountPercent: 10);
    final sent = o.toServerPayload();
    final line = (sent['lines'] as List).single as Map;
    expect(line['unit_price'], closeTo(100.8, 0.0001));
    expect(sent['discount_percent'], 0);
    final booked =
        (line['quantity'] as num).toDouble() * (line['unit_price'] as num).toDouble();
    // Delivery and tip travel as their own fields, so the lines carry food + service.
    expect(booked, closeTo(o.total, 0.0001));
  });

  test('a modifier the server can book carries the charge on its own line', () {
    final o = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      serviceChargePercent: 10,
      lines: [
        OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 100, modifiers: [
          // Backed by a product, so the server makes it a line and moves stock.
          OrderModifier(
              modifierId: 1,
              productId: 55,
              name: 'Cheese',
              quantity: 1,
              unitPrice: 20),
        ]),
      ],
    );
    final line = (o.toServerPayload()['lines'] as List).single as Map;
    final mod = ((line['modifiers'] as List).single as Map)['unit_price'] as num;
    expect(line['unit_price'], closeTo(110, 0.0001));
    expect(mod, closeTo(22, 0.0001));
    expect(110 + 22, closeTo(o.total, 0.0001));
  });

  test('a modifier the server cannot book carries it inside its parent', () {
    final o = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      serviceChargePercent: 10,
      lines: [
        OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 100, modifiers: [
          // No product behind it, so the server has no line to make: the money
          // has to be in the parent or it is charged and never booked.
          OrderModifier(modifierId: 1, name: 'Extra spicy', quantity: 1, unitPrice: 20),
        ]),
      ],
    );
    final line = (o.toServerPayload()['lines'] as List).single as Map;
    final mod = ((line['modifiers'] as List).single as Map)['unit_price'] as num;
    expect(line['unit_price'], closeTo(132, 0.0001));
    expect(mod, 0);
    expect(132, closeTo(o.total, 0.0001));
  });

  test('the tax shown covers the service the server will tax', () {
    // Prices are tax-inclusive and the charge rides in them on the wire, so the tax on
    // the slip has to be taken on food + service or it understates what gets booked.
    final o = bill(taxRate: 10);
    final paid = o.total; // 224
    expect(o.taxTotal, closeTo(paid - paid / 1.1, 0.0001));
  });

  test('a refund of a serviced bill reverses the service too', () {
    final sale = bill();
    final credit = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      serviceChargePercent: sale.serviceChargePercent,
      lines: [
        OrderLine(productId: 1, name: 'Pizza', quantity: -2, unitPrice: 100),
      ],
    )..refundOfUuid = sale.uuid;
    expect(credit.total, -sale.total);
  });
}
