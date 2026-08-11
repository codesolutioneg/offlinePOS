import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/features/settings/shop_settings_screen.dart';

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
        home: ShopSettingsScreen(
          settings: settings,
          onChanged: () => changedCount++,
        ),
      );

  testWidgets('entering a shop name and saving persists it to the store', (t) async {
    await t.pumpWidget(app());

    await t.enterText(find.byKey(const Key('shop-name')), 'Cairo Diner');
    await t.tap(find.byKey(const Key('save-shop')));
    await t.pumpAndSettle();

    expect(settings.shopName, 'Cairo Diner');
    expect(changedCount, 1);
    expect(find.text('Saved'), findsOneWidget);
  });
}
