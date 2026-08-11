import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/features/settings/quick_comments_screen.dart';

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
        home: QuickCommentsScreen(
          settings: settings,
          onChanged: () => changedCount++,
        ),
      );

  testWidgets('lists the default quick notes when none have been set', (t) async {
    await t.pumpWidget(app());
    expect(find.byKey(const Key('comment-0')), findsOneWidget);
    expect(find.text('No onions'), findsOneWidget);
  });

  testWidgets('adding a note persists it to the settings store', (t) async {
    await t.pumpWidget(app());

    await t.enterText(find.byKey(const Key('new-comment')), 'Extra sauce');
    await t.tap(find.byKey(const Key('add-comment')));
    await t.pumpAndSettle();

    expect(settings.quickComments, contains('Extra sauce'));
    expect(find.text('Extra sauce'), findsOneWidget);
    expect(changedCount, 1);
  });

  testWidgets('removing a note persists the removal to the settings store', (t) async {
    await t.pumpWidget(app());

    final before = settings.quickComments;
    await t.tap(find.byKey(const Key('delete-comment-0')));
    await t.pumpAndSettle();

    expect(settings.quickComments, isNot(contains(before.first)));
    expect(changedCount, 1);
  });
}
