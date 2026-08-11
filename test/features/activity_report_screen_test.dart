import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/reports/activity_report_screen.dart';

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

  Widget app(List<Order> orders) => MaterialApp(
        home: ActivityReportScreen(
          orders: orders,
          audit: audit,
          formatAmount: (v) => v.toStringAsFixed(2),
        ),
      );

  testWidgets(
      'renders refunds from the order list and voided/cancelled entries from the audit log',
      (tester) async {
    // A fixed uuid so the cancelled-order tile's short reference is predictable.
    final original = Order(
      uuid: 'aaaaaaaa-1111-2222-3333-444444444444',
      deviceId: 'till-1',
      cashierId: 'sara',
      lines: [OrderLine(productId: 1, name: 'Burger', quantity: 1, unitPrice: 50)],
    );

    final refund = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      refundOfUuid: original.uuid,
      note: 'Customer complaint',
      lines: [OrderLine(productId: 1, name: 'Burger', quantity: -1, unitPrice: 50)],
    );

    audit.record('sara', 'line.voided', detail: '${original.uuid}|Fries x1|Wrong order');
    audit.record('sara', 'order.cancelled', detail: original.uuid);

    await tester.pumpWidget(app([original, refund]));

    expect(find.text('Cancelled, voided & refunded'), findsOneWidget);

    // The refund amount appears both in the overview summary and in the
    // refund row itself.
    expect(find.text('50.00'), findsWidgets);
    expect(find.textContaining('Customer complaint'), findsOneWidget);

    // The voided line: item text and reason parsed out of the audit detail.
    expect(find.text('Fries x1'), findsOneWidget);
    expect(find.textContaining('Wrong order'), findsOneWidget);

    // The cancelled order: its short reference derived from the uuid.
    expect(find.textContaining('AAAAAA'), findsOneWidget);

    // No empty states should show: every section has at least one row.
    expect(find.text('No refunds'), findsNothing);
    expect(find.text('No voided lines'), findsNothing);
    expect(find.text('No cancelled orders'), findsNothing);
  });

  testWidgets('shows the empty-state text for each section when nothing happened',
      (tester) async {
    await tester.pumpWidget(app(const []));

    expect(find.text('No refunds'), findsOneWidget);
    expect(find.text('No voided lines'), findsOneWidget);
    expect(find.text('No cancelled orders'), findsOneWidget);
  });
}
