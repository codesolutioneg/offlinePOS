import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/theme/app_colors.dart';
import 'package:offline_pos/features/support/audit_log_screen.dart';

import '../db/sqlite_loader.dart';

void main() {
  late Db db;
  late AuditLog audit;

  setUpAll(useSystemSqlite);
  setUp(() {
    // The platform has no real clipboard in a widget test; without a mock
    // handler here Clipboard.setData never resolves and the export test hangs.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') return null;
      return null;
    });
    db = Db.open(':memory:');
    audit = AuditLog(db);
    audit.record('sara', 'order.paid', detail: 'order-1');
    audit.record('sara', 'line.voided', detail: 'burger');
    audit.record('omar', 'order.cancelled', detail: 'order-2');
  });
  tearDown(() => db.close());

  Widget app() => MaterialApp(home: AuditLogScreen(audit: audit));

  testWidgets('lists recorded audit entries', (t) async {
    await t.pumpWidget(app());

    expect(find.textContaining('order.paid'), findsWidgets);
    expect(find.textContaining('line.voided'), findsWidgets);
    expect(find.textContaining('order.cancelled'), findsWidgets);
    expect(find.textContaining('sara'), findsWidgets);
    expect(find.textContaining('omar'), findsWidgets);
  });

  testWidgets('filtering by an event kind narrows the list', (t) async {
    await t.pumpWidget(app());

    await t.tap(find.byKey(const Key('audit-filter')));
    await t.pumpAndSettle();
    await t.tap(find.text('line.voided').last);
    await t.pumpAndSettle();

    expect(find.textContaining('line.voided'), findsWidgets);
    expect(find.textContaining('order.paid'), findsNothing);
    expect(find.textContaining('order.cancelled'), findsNothing);
  });

  testWidgets('exporting copies a CSV of the currently filtered rows', (t) async {
    await t.pumpWidget(app());

    await t.tap(find.byKey(const Key('audit-export')));
    await t.pumpAndSettle();

    expect(find.text('Audit log copied as CSV'), findsOneWidget);
  });

  testWidgets('each event family is tinted its own colour', (t) async {
    await t.pumpWidget(app());

    Color iconColorOf(int id) => t
        .widget<Icon>(find.descendant(
          of: find.byKey(Key('audit-row-$id')),
          matching: find.byType(Icon),
        ))
        .color!;

    // Ids follow insertion order from setUp above: 1 = order.paid,
    // 2 = line.voided, 3 = order.cancelled (the list itself renders newest
    // first, but the row keys are the stable ids).
    expect(iconColorOf(1), AppColors.success); // order.paid
    expect(iconColorOf(2), AppColors.error); // line.voided
    expect(iconColorOf(3), AppColors.error); // order.cancelled
  });

  testWidgets('an empty audit trail shows the empty state', (t) async {
    db.close();
    db = Db.open(':memory:');
    audit = AuditLog(db);

    await t.pumpWidget(app());

    expect(find.text('No audit entries'), findsOneWidget);
  });
}
