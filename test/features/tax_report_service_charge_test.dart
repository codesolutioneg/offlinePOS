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

  testWidgets('the net taxed includes the service the server will tax', (t) async {
    final o = sale();
    await open(t, o);
    // The charge rides in the line prices on the wire, so the server taxes it too:
    // the net is 200 food + 24 service, and the tax is charged on that.
    expect(find.text('224.00'), findsWidgets);
    expect(find.text(o.taxTotal.toStringAsFixed(2)), findsWidgets);
    expect(o.taxTotal, closeTo(22.4, 0.0001));
  });

  testWidgets('the gross is the net plus the tax charged on it', (t) async {
    final o = sale();
    await open(t, o);
    // 224 net + 22.40 tax: what the customer actually handed over, which is also
    // what the sale states as its total.
    expect(find.text('246.40'), findsWidgets);
    expect(o.total, closeTo(246.4, 0.0001));
  });

  testWidgets('a sale with no service charge taxes the food alone', (t) async {
    final o = sale(servicePercent: 0);
    await open(t, o);
    expect(find.text('200.00'), findsWidgets); // net
    expect(find.text('220.00'), findsWidgets); // gross
    expect(o.taxTotal, closeTo(20, 0.0001));
  });
}
