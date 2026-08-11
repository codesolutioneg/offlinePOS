import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/features/settings/receipt_designer_screen.dart';

import '../db/sqlite_loader.dart';

void main() {
  late Db db;
  late SettingsStore settings;
  int changedCount = 0;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    settings = SettingsStore(db);
    changedCount = 0;
  });
  tearDown(() => db.close());

  Widget app() => MaterialApp(
        home: ReceiptDesignerScreen(
          settings: settings,
          onChanged: () => changedCount++,
        ),
      );

  testWidgets('toggling cashier off, entering a header, and saving persists both', (t) async {
    await t.pumpWidget(app());

    await t.enterText(find.byKey(const Key('receipt-header')), 'Cairo Diner');
    await t.tap(find.byKey(const Key('t-cashier')));
    await t.tap(find.byKey(const Key('save-receipt')));
    await t.pumpAndSettle();

    expect(settings.getString('receipt_header'), 'Cairo Diner');
    expect(settings.getBool('receipt_show_cashier', fallback: true), false);
    expect(changedCount, 1);
    expect(find.text('Saved'), findsOneWidget);
  });
}
