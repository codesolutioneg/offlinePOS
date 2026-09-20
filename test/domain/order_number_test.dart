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

    test('legacy DDMM-SEQ-TAG keeps day+seq so two days do not share #6', () {
      final a = Order(deviceId: 'd', cashierId: 'c', orderNo: '2009-006-D50');
      final b = Order(deviceId: 'd', cashierId: 'c', orderNo: '1909-006-D50');
      expect(a.displayNo, '20096');
      expect(b.displayNo, '19096');
      expect(a.displayNo, isNot(b.displayNo));
    });

    test('displayNo is unchanged for plain sequential numbers', () {
      final o = Order(deviceId: 'd', cashierId: 'c', orderNo: '42');
      expect(o.displayNo, '42');
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

    test('counts up and never restarts at a new trading day', () {
      expect(settings.nextOrderNumber('till-a1b', now: DateTime(2026, 8, 15, 12)),
          '1');
      expect(settings.nextOrderNumber('till-a1b', now: DateTime(2026, 8, 15, 18)),
          '2');
      // Next calendar / trading day keeps climbing — no second "#1".
      expect(settings.nextOrderNumber('till-a1b', now: DateTime(2026, 8, 16, 9)),
          '3');
    });

    test('atLeast climbs past numbers already issued elsewhere', () {
      expect(settings.nextOrderNumber('till-a1b', atLeast: 100), '101');
      expect(settings.nextOrderNumber('till-a1b'), '102');
    });

    test('a device id with nothing to take a tag from still gets one', () {
      expect(SettingsStore.tillTagFor('--'), 'XXX');
      expect(SettingsStore.tillTagFor('t1'), 'XT1');
    });
  });
}
