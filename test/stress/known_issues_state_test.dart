@Tags(['stress', 'known-issue'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/domain/business_day.dart';
import 'package:offline_pos/domain/order.dart';

import '../db/sqlite_loader.dart';
import 'stress_till.dart';

/// Reproductions of the day, cashier and queue findings in
/// `docs/POS_TEST_INCIDENTS_VS_OFFLINEPOS.md`. Each test states what a correct
/// till must do, so it fails for as long as the finding is still in the code.
void main() {
  late StressTill till;

  setUpAll(useSystemSqlite);
  setUp(() => till = StressTill());
  tearDown(() => till.close());

  test('C5 · a table opened yesterday and paid today books on today', () {
    final opened = DateTime.now().toUtc().subtract(const Duration(hours: 26));
    till.orders.save(
      Order(
        deviceId: till.deviceId,
        cashierId: 'sara',
        createdAt: opened,
        tableLabel: 'T2',
        lines: [OrderLine(productId: 1, name: 'Item 1', quantity: 1, unitPrice: 25)],
      ),
      announce: false,
    );

    final sale = till.payCash(till.session());

    expect(sale.businessDay, BusinessDay.of(DateTime.now().toUtc()),
        reason: 'the money came in today but the sale books on ${sale.businessDay}');
  });

  test('M3 · a new cashier does not inherit the last cashier\'s cart', () {
    final sara = till.session();
    till.ring(sara, lines: 2);

    final omar = till.session(cashierId: 'omar');
    final sale = till.payCash(omar);

    expect(sale.cashierId, 'omar',
        reason: 'Omar took the money but the sale is filed under ${sale.cashierId}');
  });

  test('H2 · an edit queued while the mirror is sending is not lost', () async {
    const uuid = 'order-1';
    late Outbox outbox;
    var calls = 0;
    outbox = Outbox(store: till.outboxStore, senders: {
      'mirror': (entry) async {
        calls++;
        if (calls == 1) {
          // The cashier re-pays the order while the first send is on the wire.
          await outbox.enqueue('mirror', uuid, {'state': 'paid', 'rev': 2});
        }
      },
    });
    await outbox.enqueue('mirror', uuid, {'state': 'cancelled', 'rev': 1});

    await outbox.drain();
    await outbox.drain();

    expect(calls, 2,
        reason: 'the newer payload (rev 2) was marked sent without ever going out');
  });
}
