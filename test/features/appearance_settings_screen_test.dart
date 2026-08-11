import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/features/settings/appearance_settings_screen.dart';

import '../db/sqlite_loader.dart';

void main() {
  late Db db;
  late SettingsStore settings;
  int changedCount = 0;

  const categories = [
    Category(id: 1, name: 'Drinks'),
    Category(id: 2, name: 'Mains'),
  ];

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    settings = SettingsStore(db);
    changedCount = 0;
  });
  tearDown(() => db.close());

  Widget app() => MaterialApp(
        home: AppearanceSettingsScreen(
          settings: settings,
          categories: categories,
          onChanged: () => changedCount++,
        ),
      );

  testWidgets('lists every category by name', (t) async {
    await t.pumpWidget(app());
    expect(find.text('Drinks'), findsOneWidget);
    expect(find.text('Mains'), findsOneWidget);
  });

  testWidgets('picking a swatch stores the colour and notifies the owner', (t) async {
    await t.pumpWidget(app());

    await t.tap(find.byKey(const Key('cat-1')));
    await t.pumpAndSettle();

    final swatch = find.byKey(Key('swatch-${Colors.teal.toARGB32()}'));
    expect(swatch, findsOneWidget);
    await t.tap(swatch);
    await t.pumpAndSettle();

    expect(settings.categoryColors[1], Colors.teal.toARGB32());
    expect(changedCount, 1);
  });

  testWidgets('clearing a colour removes it from the store', (t) async {
    settings.setCategoryColor(2, Colors.pink.toARGB32());

    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('cat-2')));
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('swatch-clear')));
    await t.pumpAndSettle();

    expect(settings.categoryColors.containsKey(2), isFalse);
    expect(changedCount, 1);
  });
}
