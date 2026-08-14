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

  test('a till that never configured it charges no service', () {
    expect(settings.serviceChargePercent, 0);
    expect(settings.serviceChargePercentFor(OrderType.dineIn), 0);
  });

  test('the default types are dine-in only: a takeaway bag is not table service', () {
    settings.serviceChargePercent = 12;
    expect(settings.serviceChargeOrderTypes, {OrderType.dineIn});
    expect(settings.serviceChargePercentFor(OrderType.dineIn), 12);
    expect(settings.serviceChargePercentFor(OrderType.takeaway), 0);
    expect(settings.serviceChargePercentFor(OrderType.delivery), 0);
  });

  test('a fractional percentage round-trips', () {
    settings.serviceChargePercent = 12.5;
    expect(settings.serviceChargePercent, 12.5);
  });

  test('zero clears the setting rather than storing an off value', () {
    settings.serviceChargePercent = 12;
    settings.serviceChargePercent = 0;
    expect(settings.serviceChargePercent, 0);
    expect(settings.getString('service_charge_percent'), isNull);
  });

  test('adding a type charges it, removing one stops charging it', () {
    settings.serviceChargePercent = 10;
    settings.setServiceChargeOrderType(OrderType.delivery, true);
    expect(settings.serviceChargePercentFor(OrderType.delivery), 10);
    settings.setServiceChargeOrderType(OrderType.dineIn, false);
    expect(settings.serviceChargePercentFor(OrderType.dineIn), 0);
    expect(settings.serviceChargeOrderTypes, {OrderType.delivery});
  });

  test('unticking every type stays empty instead of reverting to the default', () {
    settings.serviceChargePercent = 10;
    settings.setServiceChargeOrderType(OrderType.dineIn, false);
    expect(settings.serviceChargeOrderTypes, isEmpty);
    for (final t in OrderType.values) {
      expect(settings.serviceChargePercentFor(t), 0);
    }
  });

  test('a corrupt stored value falls back to the default rather than throwing', () {
    settings.setString('service_charge_order_types', 'not json');
    expect(settings.serviceChargeOrderTypes, {OrderType.dineIn});
  });
}
