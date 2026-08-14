import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/lan/lan_applier.dart';
import 'package:offline_pos/core/lan/lan_event.dart';
import 'package:offline_pos/domain/order.dart';

import '../db/sqlite_loader.dart';
import 'shop.dart';

void main() {
  setUpAll(useSystemSqlite);

  late TestShop shop;
  setUp(() => shop = TestShop());
  tearDown(() => shop.close());

  /// A bump raised somewhere other than the till that owns the order, which is what a
  /// kitchen screen does: the bump is in the screen's log, the order is in the owning
  /// till's, and a third till can pull them in either order.
  LanEvent bump(Order order, {required int seq}) => LanEvent(
        kind: LanEventKind.kitchenStatus,
        originDeviceId: 'kds-1',
        seq: seq,
        recordUuid: order.uuid,
        payload: {'status': KitchenStatus.preparing.name},
        at: DateTime.utc(2026, 1, 1, 12),
      );

  LanEvent arrival(Order order, {required int seq}) => LanEvent(
        kind: LanEventKind.orderUpsert,
        originDeviceId: 'till-a',
        seq: seq,
        recordUuid: order.uuid,
        payload: order.toMap(),
        at: DateTime.utc(2026, 1, 1, 11),
      );

  test('a bump for an order that has not arrived holds the cursor, then lands', () {
    final till = shop.add('till-b');
    final order = heldOrder('till-a');

    expect(till.applier.applyAll('kds-1', [bump(order, seq: 5)], highSeq: 5), 0);
    // Held below the bump. Advancing to 5 would be the bug: nothing fetches that page
    // again, so the ticket would sit on New for the rest of the night.
    expect(till.log.cursorFor('kds-1'), 4);

    till.applier.applyAll('till-a', [arrival(order, seq: 9)], highSeq: 9);

    // The next pass asks from 4 and gets the same bump, which now has an order to move.
    expect(till.applier.applyAll('kds-1', [bump(order, seq: 5)], highSeq: 5), 1);
    expect(till.log.cursorFor('kds-1'), 5);
    expect(till.orders.byUuid(order.uuid)!.kitchenStatus, KitchenStatus.preparing);
  });

  test('a bump whose order never arrives is abandoned instead of stalling the peer', () {
    final till = shop.add('till-b');
    final order = heldOrder('till-a');

    for (var pass = 1; pass <= LanApplier.waitPasses; pass++) {
      till.applier.applyAll('kds-1', [bump(order, seq: 5)], highSeq: 5);
      expect(till.log.cursorFor('kds-1'), 4, reason: 'still waiting on pass $pass');
    }

    till.applier.applyAll('kds-1', [bump(order, seq: 5)], highSeq: 5);

    // The order was discarded on the owning till and is never coming, so the peer's
    // catch-up moves on rather than re-reading the same page for the rest of the week.
    expect(till.log.cursorFor('kds-1'), 5);
    expect(
      till.refusals.where((r) => r.startsWith('lan.event.abandoned')),
      isNotEmpty,
    );
  });

  test('a clean page resets the wait, so one miss does not spend the budget', () {
    final till = shop.add('till-b');
    final first = heldOrder('till-a', table: '1');
    final second = heldOrder('till-a', table: '2');

    for (var pass = 1; pass < LanApplier.waitPasses; pass++) {
      till.applier.applyAll('kds-1', [bump(first, seq: 5)], highSeq: 5);
    }
    till.applier.applyAll('kds-1', const [], highSeq: 6);
    expect(till.log.cursorFor('kds-1'), 6);

    // A later bump gets the whole budget again instead of inheriting the last one's.
    till.applier.applyAll('kds-1', [bump(second, seq: 8)], highSeq: 8);
    expect(till.log.cursorFor('kds-1'), 7);
  });
}
