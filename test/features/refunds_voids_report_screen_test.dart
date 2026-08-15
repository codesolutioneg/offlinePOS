import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/reports/refunds_voids_report_screen.dart';

import '../db/sqlite_loader.dart';

void main() {
  late Db db;
  late AuditLog audit;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    audit = AuditLog(db);
  });
  tearDown(() => db.close());

  Order refund(double amount, String reason, {String cashier = 'sara'}) => Order(
        deviceId: 'd',
        cashierId: cashier,
        type: OrderType.takeaway,
        refundOfUuid: 'original',
        note: reason,
      )..lines.add(OrderLine(
          productId: 1, name: 'Pizza', quantity: 1, unitPrice: -amount));

  Widget screen(List<Order> orders) => MaterialApp(
        home: RefundsVoidsReportScreen(
          orders: orders,
          audit: audit,
          formatAmount: (v) => v.toStringAsFixed(2),
        ),
      );

  testWidgets('a quiet range renders an empty state, not an error', (t) async {
    await t.pumpWidget(screen(const []));
    expect(find.byKey(const Key('refunds-voids-empty-state')), findsOneWidget);
  });

  testWidgets('refunds are totalled as positive money given back', (t) async {
    await t.pumpWidget(screen([refund(25, 'Wrong order'), refund(10, 'Wrong order')]));

    expect(find.text('35.00'), findsWidgets);
    expect(find.text('Wrong order'), findsWidgets);
  });

  testWidgets('voids and cancels from the audit join the refunds', (t) async {
    audit.record('omar', 'line.voided', detail: 'uuid-1|Chips x2|Sent back');
    audit.record('omar', 'order.cancelled', detail: 'uuid-2|Walked out');
    await t.pumpWidget(screen([refund(25, 'Wrong order')]));

    expect(find.text('Sent back'), findsWidgets);
    expect(find.text('Walked out'), findsWidgets);
    // Three events, from two sources, in one list.
    expect(find.textContaining('Chips x2'), findsOneWidget);
  });

  testWidgets('totals group by reason and by cashier', (t) async {
    audit.record('omar', 'line.voided', detail: 'uuid-1|Chips x2|Wrong order');
    await t.pumpWidget(screen([
      refund(25, 'Wrong order'),
      refund(10, 'Complaint', cashier: 'huda'),
    ]));

    // 'Wrong order' covers a refund and a void: one reason, two events.
    final reasons = t.widget<Column>(find.byKey(const Key('rv-by-reason')));
    expect(reasons.children.length, 2);
    final cashiers = t.widget<Column>(find.byKey(const Key('rv-by-cashier')));
    expect(cashiers.children.length, 3);
  });

  testWidgets('an event with no reason is still counted', (t) async {
    audit.record('omar', 'order.cancelled', detail: 'uuid-2');
    await t.pumpWidget(screen(const []));

    expect(find.textContaining('No reason'), findsWidgets);
  });
}
