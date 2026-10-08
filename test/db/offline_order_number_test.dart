import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/domain/order.dart';

import 'sqlite_loader.dart';

/// A secondary that could not reach the primary used to number from its own copy
/// of the shared counter, and printed the primary's numbers a second time.
void main() {
  setUpAll(useSystemSqlite);

  late Db db;
  late SettingsStore settings;
  setUp(() {
    db = Db.open(':memory:');
    settings = SettingsStore(db);
  });
  tearDown(() => db.close());

  const device = '565896e0-efed-4098-b11f-0e3d1aebfa4d';

  test('carries the till tag and its own sequence', () {
    expect(settings.nextOfflineOrderNumber(device), 'TA4D-1');
    expect(settings.nextOfflineOrderNumber(device), 'TA4D-2');
  });

  test('does not move the shared counter', () {
    final before = settings.nextOrderNumber(device);
    settings.nextOfflineOrderNumber(device);

    expect(int.parse(settings.nextOrderNumber(device)), int.parse(before) + 1);
  });

  test('is printed whole, not collapsed to digits', () {
    expect(Order.shortOrderNumber('TA4D-12'), 'TA4D-12');
    expect((Order(deviceId: device, cashierId: 'ana')..orderNo = 'TA4D-12').displayNo,
        'TA4D-12');
    expect(Order.shortOrderNumber('705'), '705');
  });

  test('never raises the floor the shared counter climbs past', () {
    final orders = OrderStore(db, ownDeviceId: device);
    orders.save(Order(deviceId: device, cashierId: 'ana')..orderNo = '705');
    orders.save(Order(deviceId: device, cashierId: 'ana')..orderNo = 'TA4D-999');

    expect(orders.orderNumberFloor(), 705);
  });
}
