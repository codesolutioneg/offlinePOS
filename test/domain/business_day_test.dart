import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/business_day.dart';
import 'package:offline_pos/domain/order.dart';

void main() {
  test('an evening sale belongs to that day', () {
    expect(BusinessDay.of(DateTime(2026, 3, 10, 21, 30)).key, '2026-03-10');
  });

  test('a sale after midnight still belongs to the evening that produced it', () {
    // The single most important case: a restaurant closing at 02:00 must not have
    // its service split across two daily reports and two cash-ups.
    expect(BusinessDay.of(DateTime(2026, 3, 11, 1, 15)).key, '2026-03-10');
  });

  test('the cutover hour starts the new trading day', () {
    expect(BusinessDay.of(DateTime(2026, 3, 11, 4, 0)).key, '2026-03-11');
    expect(BusinessDay.of(DateTime(2026, 3, 11, 3, 59)).key, '2026-03-10');
  });

  test('the cutover is configurable for shops that close earlier', () {
    expect(BusinessDay.of(DateTime(2026, 3, 11, 2, 0), cutoverHour: 0).key,
        '2026-03-11');
  });

  test('a month boundary rolls back correctly', () {
    expect(BusinessDay.of(DateTime(2026, 4, 1, 0, 30)).key, '2026-03-31');
  });

  test('a shop that publishes its own cutover moves the boundary', () {
    BusinessDay.shopCutoverHour = 5;
    addTearDown(() => BusinessDay.shopCutoverHour = BusinessDay.defaultCutoverHour);
    // A 03:00 sale under a 05:00 cutover is still the night before's trading.
    expect(BusinessDay.of(DateTime(2026, 3, 11, 3, 0)).key, '2026-03-10');
    expect(BusinessDay.of(DateTime(2026, 3, 11, 5, 0)).key, '2026-03-11');
    // An order stamps the rule when it is created, so moving the rule afterwards
    // cannot re-date a sale that is already counted.
    final order = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      createdAt: DateTime(2026, 3, 11, 3, 0),
    );
    expect(order.businessDay.key, '2026-03-10');
    BusinessDay.shopCutoverHour = 0;
    expect(order.businessDay.key, '2026-03-10');
    expect(order.toMap()['business_date'], '2026-03-10');
  });

  test('an order rung before the cutover was configurable keeps the old rule', () {
    BusinessDay.shopCutoverHour = 0;
    addTearDown(() => BusinessDay.shopCutoverHour = BusinessDay.defaultCutoverHour);
    final legacy = Order.fromMap({
      'uuid': 'u1',
      'device_id': 'till-1',
      'cashier_id': 'sara',
      'created_at': DateTime(2026, 3, 11, 1, 0).toIso8601String(),
      'state': 'paid',
      'order_type': 'dineIn',
    });
    expect(legacy.businessDayCutoverHour, BusinessDay.defaultCutoverHour);
    expect(legacy.businessDay.key, '2026-03-10');
  });

  test('an order carries the trading day it was rung on, not the sync day', () {
    final order = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      createdAt: DateTime(2026, 3, 11, 1, 0).toUtc(),
    );
    final map = order.toMap();
    expect(map['business_date'], isNotNull);
    // The moment of sale survives into the payload.
    expect(map['created_at'], order.createdAt.toIso8601String());
    expect(map['cashier_id'], 'sara');
    expect(map['uuid'], order.uuid);
  });
}
