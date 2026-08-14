import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/reports/tax_report_screen.dart';

void main() {
  Order sale({double servicePercent = 12}) => Order(
        deviceId: 'till-1',
        cashierId: 'sara',
        serviceChargePercent: servicePercent,
        lines: [
          OrderLine(
              productId: 1, name: 'Pizza', quantity: 2, unitPrice: 100, taxRate: 10),
        ],
      );

  Future<void> open(WidgetTester t, Order o) => t.pumpWidget(MaterialApp(
        home: TaxReportScreen(
          orders: [o],
          formatAmount: (v) => v.toStringAsFixed(2),
        ),
      ));

  testWidgets('the gross taxed includes the service the server will tax', (t) async {
    final o = sale();
    await open(t, o);
    // The charge rides in the line prices on the wire, so the taxed gross is what the
    // customer paid: 200 food + 24 service.
    expect(find.text('224.00'), findsWidgets);
    expect(find.text(o.taxTotal.toStringAsFixed(2)), findsWidgets);
  });

  testWidgets('a sale with no service charge reports exactly as before', (t) async {
    await open(t, sale(servicePercent: 0));
    expect(find.text('200.00'), findsWidgets);
  });
}
