import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/domain/business_day.dart';
import 'package:offline_pos/domain/order.dart';
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

  /// The screen is longer than a short till, so reach a control the way a manager
  /// would rather than tapping at a coordinate past the bottom.
  Future<void> scrollTo(WidgetTester t, String key) async {
    // The page list, not the text fields' own scrollers.
    await t.scrollUntilVisible(find.byKey(Key(key)), 200,
        scrollable: find.byType(Scrollable).first);
    await t.pumpAndSettle();
  }

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
    await scrollTo(t, 'save-shop');
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
    await scrollTo(t, 'business-day-cutover');
    await t.tap(find.byKey(const Key('business-day-cutover')));
    await t.pumpAndSettle();
    await t.tap(find.text('05:00').last);
    await t.pumpAndSettle();
    await scrollTo(t, 'save-shop');
    await t.tap(find.byKey(const Key('save-shop')));
    await t.pumpAndSettle();

    expect(settings.businessDayCutoverHour, 5);
    // Saved and published in one step, so an order rung straight after is stamped
    // with the new rule rather than waiting for a restart.
    expect(BusinessDay.shopCutoverHour, 5);
  });

  testWidgets('a shop that does not deliver turns delivery off for everyone',
      (t) async {
    await t.pumpWidget(app());

    await scrollTo(t, 'shop-type-delivery');
    await t.tap(find.byKey(const Key('shop-type-delivery')));
    await t.pumpAndSettle();
    await scrollTo(t, 'save-shop');
    await t.tap(find.byKey(const Key('save-shop')));
    await t.pumpAndSettle();

    expect(settings.shopOrderTypes.contains(OrderType.delivery), isFalse);
    expect(settings.availableOrderTypesFor('cashier').contains(OrderType.delivery),
        isFalse);
  });

  testWidgets('the floor sections can be moved back above the plan', (t) async {
    await t.pumpWidget(app());

    expect(settings.floorSectionsSide, isTrue);
    await scrollTo(t, 'sections-top');
    await t.tap(find.byKey(const Key('sections-top')));
    await t.pumpAndSettle();
    await scrollTo(t, 'save-shop');
    await t.tap(find.byKey(const Key('save-shop')));
    await t.pumpAndSettle();

    expect(settings.floorSectionsSide, isFalse);
  });
}
