import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/printing/receipt_builder.dart';
import 'package:offline_pos/domain/order.dart';

import 'strip_escpos.dart';

ReceiptBuilder builder() => ReceiptBuilder(
      shopName: 'JOUMA',
      formatAmount: (v) => v.toStringAsFixed(2),
    );

String render(Order o) => strippedText(builder().build(o));

Order bill({double servicePercent = 12, double discountPercent = 0}) => Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      serviceChargePercent: servicePercent,
      discountPercent: discountPercent,
      lines: [
        OrderLine(productId: 1, name: 'Pizza', quantity: 2, unitPrice: 100),
      ],
    );

void main() {
  test('the service charge prints as its own line between subtotal and total', () {
    final lines = render(bill()).split('\n');
    final subtotal = lines.indexWhere((l) => l.contains('Subtotal'));
    final service = lines.indexWhere((l) => l.contains('Service'));
    final total = lines.indexWhere((l) => l.contains('TOTAL'));
    expect(subtotal, greaterThan(-1));
    expect(service, greaterThan(subtotal));
    expect(total, greaterThan(service));
    expect(lines[service], contains('Service 12%'));
    expect(lines[service], contains('24.00'));
    expect(lines[total], contains('224.00'));
  });

  test('a fractional percentage prints without a trailing zero', () {
    expect(render(bill(servicePercent: 12.5)), contains('Service 12.5%'));
  });

  test('it prints after the discount, because that is what it is charged on', () {
    final lines = render(bill(discountPercent: 10)).split('\n');
    final discount = lines.indexWhere((l) => l.contains('Discount'));
    final service = lines.indexWhere((l) => l.contains('Service'));
    expect(service, greaterThan(discount));
    expect(lines[service], contains('21.60')); // 200 less 10%, then 12%
  });

  test('a bill with no charge prints no service line at all', () {
    final s = render(bill(servicePercent: 0));
    expect(s.contains('Service'), isFalse);
    expect(s.contains('Subtotal'), isFalse); // still a plain receipt
  });

  test('a deletion slip nets the service off what was removed', () {
    final order = bill();
    final slip = strippedText(builder().buildDeletion(
      order,
      order.lines,
      title: 'VOID',
      at: DateTime.utc(2026, 1, 2, 10, 30),
      reason: 'sent back',
      actor: 'sara',
    ));
    expect(slip, contains('Service 12%'));
    final removed = slip.split('\n').firstWhere((l) => l.contains('REMOVED'));
    expect(removed, contains('224.00'));
  });
}
