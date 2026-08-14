import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/settings/tax_settings_screen.dart';

import '../db/sqlite_loader.dart';

void main() {
  late Db db;
  late SettingsStore settings;
  var changed = 0;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    settings = SettingsStore(db);
    changed = 0;
  });
  tearDown(() => db.close());

  Future<void> open(WidgetTester t,
      {List<Category> categories = const [Category(id: 1, name: 'Food')]}) async {
    await t.pumpWidget(MaterialApp(
      home: TaxSettingsScreen(
        settings: settings,
        categories: categories,
        onChanged: () => changed++,
      ),
    ));
  }

  testWidgets('a manager sets the service percentage and it persists', (t) async {
    await open(t);
    await t.enterText(find.byKey(const Key('service-charge-percent')), '12');
    await t.pump();
    expect(settings.serviceChargePercent, 12);
    expect(changed, greaterThan(0));
  });

  testWidgets('clearing the field turns the charge off', (t) async {
    settings.serviceChargePercent = 12;
    await open(t);
    await t.enterText(find.byKey(const Key('service-charge-percent')), '');
    await t.pump();
    expect(settings.serviceChargePercent, 0);
  });

  testWidgets('dine-in is ticked by default and delivery is not', (t) async {
    await open(t);
    expect(
        t
            .widget<CheckboxListTile>(find.byKey(const Key('service-type-dineIn')))
            .value,
        isTrue);
    expect(
        t
            .widget<CheckboxListTile>(find.byKey(const Key('service-type-delivery')))
            .value,
        isFalse);
  });

  testWidgets('ticking a type charges it and unticking one stops', (t) async {
    settings.serviceChargePercent = 10;
    await open(t);
    await t.tap(find.byKey(const Key('service-type-takeaway')));
    await t.pump();
    expect(settings.serviceChargePercentFor(OrderType.takeaway), 10);
    await t.tap(find.byKey(const Key('service-type-dineIn')));
    await t.pump();
    expect(settings.serviceChargePercentFor(OrderType.dineIn), 0);
  });

  testWidgets('the charge is still settable before any category exists', (t) async {
    await open(t, categories: const []);
    expect(find.byKey(const Key('service-charge-card')), findsOneWidget);
    await t.enterText(find.byKey(const Key('service-charge-percent')), '12');
    await t.pump();
    expect(settings.serviceChargePercent, 12);
    expect(find.text('No categories yet'), findsOneWidget);
  });

  testWidgets('the tax matrix still works alongside it', (t) async {
    await open(t);
    await t.enterText(find.byKey(const Key('tax-1-dineIn')), '14');
    await t.pump();
    expect(settings.categoryTaxRate(1, OrderType.dineIn), 14);
  });
}
