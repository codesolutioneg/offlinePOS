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

  /// A window tall enough for the whole options list, so a control below the fold
  /// is on screen rather than behind the pinned Save bar.
  void tallWindow(WidgetTester t) {
    t.view.physicalSize = const Size(1000, 2400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

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

  testWidgets('the what-prints toggles default on and persist when switched off', (t) async {
    tallWindow(t);
    await t.pumpWidget(app());

    for (final k in ['t-datetime', 't-number', 't-table', 't-payment', 't-itemprice']) {
      await t.tap(find.byKey(Key(k)));
    }
    await t.tap(find.byKey(const Key('save-receipt')));
    await t.pumpAndSettle();

    expect(settings.receiptShowDateTime, false);
    expect(settings.receiptShowNumber, false);
    expect(settings.receiptShowTable, false);
    expect(settings.receiptShowPayment, false);
    expect(settings.receiptShowItemPrice, false);
  });

  testWidgets('the divider style is an exclusive choice and persists', (t) async {
    tallWindow(t);
    await t.pumpWidget(app());
    expect(settings.receiptDividerStyle, 'line');

    // The segment's ink well takes the tap, not the label the key is on.
    await t.tap(find.byKey(const Key('t-divider-stars')), warnIfMissed: false);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('save-receipt')));
    await t.pumpAndSettle();

    expect(settings.receiptDividerStyle, 'stars');
  });

  testWidgets('the paper size writes the same key the printers screen uses', (t) async {
    tallWindow(t);
    settings.receiptColumns = 42;
    await t.pumpWidget(app());

    await t.tap(find.byKey(const Key('t-papersize-58')), warnIfMissed: false);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('save-receipt')));
    await t.pumpAndSettle();

    expect(settings.receiptColumns, 32);
    expect(settings.getString('receipt_columns'), '32');
  });

  testWidgets('saving leaves settings the screen did not change alone', (t) async {
    settings.receiptColumns = 32;
    settings.receiptDividerStyle = 'dots';
    await t.pumpWidget(app());

    await t.tap(find.byKey(const Key('save-receipt')));
    await t.pumpAndSettle();

    expect(settings.receiptColumns, 32);
    expect(settings.receiptDividerStyle, 'dots');
    expect(settings.receiptShowTable, true);
  });
}
