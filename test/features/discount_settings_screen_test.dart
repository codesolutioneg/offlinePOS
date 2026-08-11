import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/features/settings/discount_settings_screen.dart';

import '../db/sqlite_loader.dart';

void main() {
  late Db db;
  late SettingsStore settings;
  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    settings = SettingsStore(db);
  });
  tearDown(() => db.close());

  testWidgets('a manager can add a discount percentage and it persists', (t) async {
    await t.pumpWidget(MaterialApp(
      home: DiscountSettingsScreen(settings: settings, onChanged: () {}),
    ));
    await t.enterText(find.byKey(const Key('new-percent')), '25');
    await t.tap(find.byKey(const Key('add-percent')));
    await t.pump();
    expect(settings.discountPercents.contains(25), isTrue);
    expect(find.byKey(const Key('pct-25')), findsOneWidget);
  });

  testWidgets('the maximum discount saves', (t) async {
    await t.pumpWidget(MaterialApp(
      home: DiscountSettingsScreen(settings: settings, onChanged: () {}),
    ));
    await t.enterText(find.byKey(const Key('max-discount')), '30');
    await t.tap(find.byKey(const Key('save-max')));
    await t.pump();
    expect(settings.maxDiscountPercent, 30);
  });

  test('sold-out products round-trip through the settings store', () {
    settings.setProductAvailable(7, false);
    expect(settings.unavailableProducts, {7});
    settings.setProductAvailable(7, true);
    expect(settings.unavailableProducts, isEmpty);
  });
}
