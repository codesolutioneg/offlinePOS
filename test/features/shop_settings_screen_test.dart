import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/domain/business_day.dart';
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
  tearDown(() {
    db.close();
    BusinessDay.shopCutoverHour = BusinessDay.defaultCutoverHour;
  });

  Widget app() => MaterialApp(
        home: ShopSettingsScreen(
          settings: settings,
          onChanged: () => changedCount++,
        ),
      );

  /// The settings list is longer than the default test window, and Save is at the
  /// bottom of it.
  void tallWindow(WidgetTester t) {
    t.view.physicalSize = const Size(800, 1600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

  testWidgets('entering a shop name and saving persists it to the store', (t) async {
    tallWindow(t);
    await t.pumpWidget(app());

    await t.enterText(find.byKey(const Key('shop-name')), 'Cairo Diner');
    await t.tap(find.byKey(const Key('save-shop')));
    await t.pumpAndSettle();

    expect(settings.shopName, 'Cairo Diner');
    expect(changedCount, 1);
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('a shop that closes at 03:00 can move its trading-day cutover',
      (t) async {
    tallWindow(t);
    await t.pumpWidget(app());

    expect(settings.businessDayCutoverHour, BusinessDay.defaultCutoverHour);
    await t.tap(find.byKey(const Key('business-day-cutover')));
    await t.pumpAndSettle();
    await t.tap(find.text('05:00').last);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('save-shop')));
    await t.pumpAndSettle();

    expect(settings.businessDayCutoverHour, 5);
    // Saved and published in one step, so an order rung straight after is stamped
    // with the new rule rather than waiting for a restart.
    expect(BusinessDay.shopCutoverHour, 5);
  });
}
