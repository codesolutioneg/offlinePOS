@Tags(['stress'])
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/dev/latency_stats.dart';

import '../db/sqlite_loader.dart';
import 'stress_till.dart';

/// Load on one till, through the same session code a cashier drives.
///
/// Selling in offlinePOS never waits on a server, so "does it hold up" means:
/// does paying stay fast as the day fills up, does every sale get its own number,
/// and does every sale land in the queue that closes the shift to Odoo.
void main() {
  late StressTill till;

  setUpAll(useSystemSqlite);
  setUp(() => till = StressTill());
  tearDown(() => till.close());

  test('100 orders back to back: all saved, numbered once, queued once', () {
    final s = till.session();
    final timings = <int>[];
    var takings = 0.0;
    final clock = Stopwatch()..start();
    for (var i = 0; i < 100; i++) {
      till.ring(s, lines: 3 + i % 4, seed: i);
      final sw = Stopwatch()..start();
      final sale = till.payCash(s);
      timings.add(sw.elapsedMicroseconds);
      takings += sale.total;
    }
    clock.stop();
    final stats = LatencyStats(timings);
    debugPrint('[STRESS] 100 orders in ${clock.elapsedMilliseconds} ms · pay() $stats');

    final sales = till.orders.recent(limit: 1000);
    expect(sales, hasLength(100));
    final numbers = sales.map((o) => o.orderNo).toSet();
    expect(numbers, hasLength(100), reason: 'every sale must carry its own number');
    expect(numbers.contains(null), isFalse);
    expect(till.outboxStore.pendingSalesCount, 100,
        reason: 'every paid sale must be waiting for the shift close');
    final paid = sales.fold<double>(0, (a, o) => a + o.amountPaid);
    expect(paid, closeTo(takings, 0.01));
    expect(stats.percentileMs(0.95), lessThan(50),
        reason: 'a cashier should never wait on pay(): $stats');
  });

  test('fill 60 tables, then settle every one of them', () {
    final s = till.session();
    final clock = Stopwatch()..start();
    for (var t = 1; t <= 60; t++) {
      till.ring(s, lines: 4, seed: t);
      s.hold(table: 'T$t');
    }
    final fillMs = clock.elapsedMilliseconds;
    final held = till.orders.held();
    expect(held, hasLength(60));
    expect(held.map((o) => o.tableLabel).toSet(), hasLength(60));
    expect(held.map((o) => o.orderNo).toSet(), hasLength(60),
        reason: 'two open tables must never share a kitchen number');

    clock.reset();
    for (final tab in held) {
      s.recall(tab.uuid);
      till.payCash(s);
    }
    debugPrint('[STRESS] filled 60 tables in $fillMs ms, '
        'settled them in ${clock.elapsedMilliseconds} ms');

    expect(till.orders.held(), isEmpty);
    final sales = till.orders.recent(limit: 1000);
    expect(sales, hasLength(60));
    expect(sales.every((o) => o.state == OrderState.paid), isTrue);
    expect(sales.map((o) => o.orderNo).toSet(), hasLength(60),
        reason: 'a table keeps the number it was sent to the kitchen with');
    expect(till.outboxStore.pendingSalesCount, 60);
  });

  test('pay() stays fast on a till that already holds 5000 sales', () {
    final base = DateTime.now().toUtc().subtract(const Duration(days: 3));
    till.db.raw.execute('BEGIN');
    for (var i = 0; i < 5000; i++) {
      final o = Order(
        deviceId: till.deviceId,
        cashierId: 'sara',
        createdAt: base.add(Duration(seconds: i * 30)),
        orderNo: '${i + 1}',
        lines: [
          OrderLine(productId: 1, name: 'Item 1', quantity: 2, unitPrice: 25),
          OrderLine(productId: 2, name: 'Item 2', quantity: 1, unitPrice: 30),
        ],
      )..state = OrderState.synced;
      till.orders.save(o, announce: false);
    }
    till.db.raw.execute('COMMIT');

    final s = till.session();
    final timings = <int>[];
    for (var i = 0; i < 30; i++) {
      till.ring(s, lines: 3, seed: i);
      final sw = Stopwatch()..start();
      till.payCash(s);
      timings.add(sw.elapsedMicroseconds);
    }
    final stats = LatencyStats(timings);
    debugPrint('[STRESS] pay() with 5000 sales already on the till: $stats');

    expect(till.orders.recent(limit: 1).single.orderNo, '5030');
    expect(stats.percentileMs(0.95), lessThan(50),
        reason: 'finding the next number must not slow Pay down (report M8): $stats');
  });
}
