import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/features/settings/discount_reasons_screen.dart';

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
        home: DiscountReasonsScreen(
          settings: settings,
          onChanged: () => changedCount++,
        ),
      );

  testWidgets('lists the default discount reasons', (t) async {
    await t.pumpWidget(app());
    expect(find.byKey(const Key('reason-0')), findsOneWidget);
    expect(find.text('Manager comp'), findsOneWidget);
  });

  testWidgets('adding a reason appends it and persists to the store', (t) async {
    await t.pumpWidget(app());

    await t.enterText(find.byKey(const Key('new-reason')), 'Regular customer');
    await t.tap(find.byKey(const Key('add-reason')));
    await t.pumpAndSettle();

    expect(find.text('Regular customer'), findsOneWidget);
    expect(settings.discountReasons, contains('Regular customer'));
    expect(changedCount, 1);
  });

  testWidgets('removing a reason deletes it and persists to the store', (t) async {
    await t.pumpWidget(app());

    final before = settings.discountReasons;
    await t.tap(find.byKey(const Key('delete-reason-0')));
    await t.pumpAndSettle();

    expect(find.byKey(Key('reason-${before.length - 1}')), findsNothing);
    expect(settings.discountReasons, isNot(contains(before.first)));
    expect(changedCount, 1);
  });
}
