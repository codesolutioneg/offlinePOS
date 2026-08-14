import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/domain/order.dart';

import 'sqlite_loader.dart';

void main() {
  late Db db;
  late SettingsStore settings;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    settings = SettingsStore(db);
  });
  tearDown(() => db.close());

  test('a category tax rate is stored per order type and read back', () {
    settings.setCategoryTaxRate(1, OrderType.dineIn, 14);
    settings.setCategoryTaxRate(1, OrderType.takeaway, 0);
    expect(settings.categoryTaxRate(1, OrderType.dineIn), 14);
    expect(settings.categoryTaxRate(1, OrderType.takeaway), 0);
    // Delivery was never set for this category, so it has no override.
    expect(settings.categoryTaxRate(1, OrderType.delivery), isNull);
    // A different, unconfigured category has no override at all.
    expect(settings.categoryTaxRate(2, OrderType.dineIn), isNull);
  });

  test('clearing a rate removes only that entry, and an empty category drops out', () {
    settings.setCategoryTaxRate(1, OrderType.dineIn, 14);
    settings.setCategoryTaxRate(1, OrderType.takeaway, 0);
    settings.setCategoryTaxRate(1, OrderType.takeaway, null); // clear takeaway
    expect(settings.categoryTaxRate(1, OrderType.takeaway), isNull);
    expect(settings.categoryTaxRate(1, OrderType.dineIn), 14);

    settings.setCategoryTaxRate(1, OrderType.dineIn, null); // now empty
    expect(settings.categoryTaxRates.containsKey(1), isFalse);
  });
}
