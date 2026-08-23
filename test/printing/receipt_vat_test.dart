import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/printing/receipt_builder.dart';
import 'package:offline_pos/domain/order.dart';

import 'strip_escpos.dart';

/// The slip has to be addable: the rows a guest reads must reach the figure they
/// paid, with the tax shown as the charge it is rather than a note about the total.
ReceiptBuilder builder() => ReceiptBuilder(
      shopName: 'JOUMA',
      formatAmount: (v) => v.toStringAsFixed(2),
    );

String render(Order o) => strippedText(builder().build(o));

Order bill({
  double taxRate = 14,
  double servicePercent = 0,
  double delivery = 0,
  double tip = 0,
  List<OrderLine>? lines,
}) =>
    Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      serviceChargePercent: servicePercent,
      deliveryCost: delivery,
      tip: tip,
      lines: lines ??
          [
            OrderLine(
                productId: 1,
                name: 'Pizza',
                quantity: 2,
                unitPrice: 100,
                taxRate: taxRate),
          ],
    );

void main() {
  test('the tax prints as its own row and the total includes it', () {
    final o = bill();
    final lines = render(o).split('\n');
    final subtotal = lines.indexWhere((l) => l.contains('Subtotal'));
    final vat = lines.indexWhere((l) => l.contains('VAT'));
    final total = lines.indexWhere((l) => l.contains('TOTAL'));
    expect(subtotal, greaterThan(-1));
    expect(vat, greaterThan(subtotal));
    expect(total, greaterThan(vat));
    expect(lines[subtotal], contains('200.00'));
    expect(lines[vat], contains('VAT 14%'));
    expect(lines[vat], contains('28.00'));
    expect(lines[total], contains('228.00'));
  });

  test('a taxed sale prints a subtotal even with nothing else on the bill', () {
    // Without it the slip would jump from the items to a tax row with no net figure
    // to add it to.
    expect(render(bill()), contains('Subtotal'));
  });

  test('an untaxed sale prints no tax row at all', () {
    final printed = render(bill(taxRate: 0));
    expect(printed.contains('VAT'), isFalse);
    expect(printed, contains('200.00'));
  });

  test('delivery and tip print after the tax, because they are outside it', () {
    final lines = render(bill(delivery: 30, tip: 10)).split('\n');
    final vat = lines.indexWhere((l) => l.contains('VAT'));
    final delivery = lines.indexWhere((l) => l.contains('Delivery'));
    final tip = lines.indexWhere((l) => l.contains('Tip'));
    final total = lines.indexWhere((l) => l.contains('TOTAL'));
    expect(delivery, greaterThan(vat));
    expect(tip, greaterThan(delivery));
    expect(lines[vat], contains('28.00'));
    expect(lines[total], contains('268.00'));
  });

  test('the tax row sits under the service it is charged on', () {
    final lines = render(bill(servicePercent: 12)).split('\n');
    final service = lines.indexWhere((l) => l.contains('Service'));
    final vat = lines.indexWhere((l) => l.contains('VAT'));
    final total = lines.indexWhere((l) => l.contains('TOTAL'));
    expect(vat, greaterThan(service));
    expect(lines[vat], contains('31.36'));
    expect(lines[total], contains('255.36'));
  });

  test('a bill of mixed rates prints the plain label', () {
    final printed = render(bill(lines: [
      OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 100, taxRate: 14),
      OrderLine(productId: 2, name: 'Water', quantity: 1, unitPrice: 50, taxRate: 5),
    ]));
    expect(printed, contains('VAT '));
    expect(printed.contains('VAT 14%'), isFalse);
  });
}
