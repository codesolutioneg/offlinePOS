import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/domain/business_day.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/reports/report_period_dialog.dart';

import '../db/sqlite_loader.dart';

/// Reports read the trading day and every sale in it: "Today" at 1am still
/// holds the evening service, and a busy week is not cut at the last thousand.
void main() {
  final today = ReportPeriodChoice.preset(ReportRange.today, 'Today');
  final yesterday = ReportPeriodChoice.preset(ReportRange.yesterday, 'Yesterday');

  setUp(() => BusinessDay.shopCutoverHour = 4);
  tearDown(() => BusinessDay.shopCutoverHour = BusinessDay.defaultCutoverHour);

  group('M5 · "Today" is the trading day', () {
    final oneAm = DateTime(2026, 8, 14, 1);

    test('at 1am the evening service is still today', () {
      expect(today.contains(DateTime(2026, 8, 13, 22), now: oneAm), isTrue,
          reason: 'the night shift fell off "Today" at midnight');
      expect(today.contains(DateTime(2026, 8, 14, 0, 30), now: oneAm), isTrue);
    });

    test('the night before the last cutover is yesterday, not today', () {
      final lastNight = DateTime(2026, 8, 13, 3);

      expect(today.contains(lastNight, now: oneAm), isFalse);
      expect(yesterday.contains(lastNight, now: oneAm), isTrue);
    });

    test('the window opens at the cutover hour', () {
      final (from, to) = today.window(now: oneAm);

      expect(from, DateTime(2026, 8, 13, 4));
      expect(to, isNull);
    });
  });

  group('M5 · a report holds every sale in its window', () {
    late Db db;
    late OrderStore orders;

    setUpAll(useSystemSqlite);
    setUp(() {
      db = Db.open(':memory:');
      orders = OrderStore(db, ownDeviceId: 'till-1');
    });
    tearDown(() => db.close());

    Order sale(DateTime at, {String device = 'till-1'}) => Order(
          deviceId: device,
          cashierId: 'sara',
          createdAt: at.toUtc(),
          lines: [OrderLine(productId: 1, name: 'Tea', quantity: 1, unitPrice: 10)],
        )..state = OrderState.paid;

    test('more than the old cap of a thousand comes back', () {
      final start = DateTime(2026, 8, 10, 12);
      for (var i = 0; i < 1200; i++) {
        orders.save(sale(start.add(Duration(minutes: i))), announce: false);
      }

      final got = orders.paidBetween(from: start, to: start.add(const Duration(days: 2)));

      expect(got, hasLength(1200));
    });

    test('only the window, and only this till unless asked', () {
      final from = DateTime(2026, 8, 13, 4);
      final to = DateTime(2026, 8, 14, 4);
      orders.save(sale(DateTime(2026, 8, 13, 3)), announce: false);
      orders.save(sale(DateTime(2026, 8, 13, 22)), announce: false);
      orders.save(sale(DateTime(2026, 8, 14, 4)), announce: false);
      orders.save(sale(DateTime(2026, 8, 13, 23), device: 'till-2'), announce: false);

      expect(orders.paidBetween(from: from, to: to), hasLength(1));
      expect(orders.paidBetween(from: from, to: to, anyDevice: true), hasLength(2));
    });
  });
}
