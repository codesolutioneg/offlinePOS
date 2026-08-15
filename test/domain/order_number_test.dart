import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/domain/order.dart';

import '../db/sqlite_loader.dart';

void main() {
  group('the number on the order', () {
    test('survives being written to disk and read back', () {
      final o = Order(deviceId: 'd', cashierId: 'c', orderNo: '1508-007-A1B')
        ..lines.add(OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 10));
      expect(Order.fromMap(o.toMap()).orderNo, '1508-007-A1B');
    });

    test('never travels to the server', () {
      final o = Order(deviceId: 'd', cashierId: 'c', orderNo: '1508-007-A1B')
        ..lines.add(OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 10));
      expect(o.toServerPayload().containsKey('order_no'), isFalse);
    });

    test('an order with no number still has something to print', () {
      final o = Order(deviceId: 'd', cashierId: 'c');
      expect(o.displayNo, hasLength(6));
      expect(o.displayNo, o.uuid.replaceAll('-', '').substring(0, 6).toUpperCase());
    });
  });

  group('the till counter', () {
    late Db db;
    late SettingsStore settings;

    setUpAll(useSystemSqlite);
    setUp(() {
      db = Db.open(':memory:');
      settings = SettingsStore(db);
    });
    tearDown(() => db.close());

    test('counts up through the day', () {
      final at = DateTime(2026, 8, 15, 12);
      expect(settings.nextOrderNumber('till-a1b', now: at), '1508-001-A1B');
      expect(settings.nextOrderNumber('till-a1b', now: at), '1508-002-A1B');
      expect(settings.nextOrderNumber('till-a1b', now: at), '1508-003-A1B');
    });

    test('a service running past midnight keeps counting on the same day', () {
      expect(settings.nextOrderNumber('till-a1b', now: DateTime(2026, 8, 15, 23, 30)),
          '1508-001-A1B');
      // 01:00 is still the evening that produced it, before the 04:00 cutover.
      expect(settings.nextOrderNumber('till-a1b', now: DateTime(2026, 8, 16, 1)),
          '1508-002-A1B');
    });

    test('the next trading day starts at one again', () {
      settings.nextOrderNumber('till-a1b', now: DateTime(2026, 8, 15, 23, 30));
      expect(settings.nextOrderNumber('till-a1b', now: DateTime(2026, 8, 16, 9)),
          '1608-001-A1B');
    });

    test('two tills on one floor cannot hand out the same number', () {
      final at = DateTime(2026, 8, 15, 12);
      expect(settings.nextOrderNumber('a1b2c3', now: at), endsWith('-2C3'));
      expect(SettingsStore.tillTagFor('a1b2c3'),
          isNot(SettingsStore.tillTagFor('a1b2c4')));
    });

    test('a device id with nothing to take a tag from still gets one', () {
      expect(SettingsStore.tillTagFor('--'), 'XXX');
      expect(SettingsStore.tillTagFor('t1'), 'XT1');
    });
  });
}
