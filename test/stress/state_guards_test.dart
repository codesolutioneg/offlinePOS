import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/app/pos_session.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/domain/business_day.dart';
import 'package:offline_pos/domain/order.dart';

import '../db/sqlite_loader.dart';
import 'stress_till.dart';

/// A queue whose disk write fails, as a full or locked database would.
class _RefusingStore implements OutboxStore {
  @override
  Future<void> append(String kind, String payloadUuid, Map<String, dynamic> payload) =>
      Future<void>.error(StateError('disk full'));

  @override
  Future<List<OutboxEntry>> pending({int limit = 20, Set<String>? kinds}) async => const [];

  @override
  Future<void> markSent(int id) async {}

  @override
  Future<void> markFailed(int id, String error) async {}

  @override
  Future<void> markDead(int id, String reason) async {}
}

/// Guards for the cashier, day and queue findings fixed from
/// `docs/POS_TEST_INCIDENTS_VS_OFFLINEPOS.md`. Untagged, so they run with the
/// ordinary suite and a regression fails the build.
void main() {
  late StressTill till;

  setUpAll(useSystemSqlite);
  setUp(() => till = StressTill());
  tearDown(() => till.close());

  group('M3 · a new cashier does not inherit the last cashier\'s cart', () {
    test('the cart left behind is parked under the cashier who rang it', () {
      final sara = till.session();
      till.ring(sara, lines: 2);
      final left = sara.current.uuid;

      final omar = till.session(cashierId: 'omar');

      expect(omar.current.lines, isEmpty);
      final parked = till.orders.byUuid(left);
      expect(parked?.state, OrderState.held);
      expect(parked?.cashierId, 'sara');
      expect(parked?.orderNo, isNotNull, reason: 'a parked tab must be findable');
    });

    test('what the new cashier rings and pays is filed under them', () {
      till.ring(till.session(), lines: 2);

      final omar = till.session(cashierId: 'omar');
      till.ring(omar, lines: 1, seed: 7);
      final sale = till.payCash(omar);

      expect(sale.cashierId, 'omar');
      expect(sale.lines, hasLength(1));
    });

    test('the same cashier signing back in gets their own cart back', () {
      final sara = till.session();
      till.ring(sara, lines: 2);
      final uuid = sara.current.uuid;

      expect(till.session().current.uuid, uuid);
    });
  });

  group('M7 · an order in progress never ends up on no screen', () {
    test('a second draft of the same cashier is parked, not left invisible', () {
      final sara = till.session();
      till.ring(sara, lines: 1);
      final stray = Order(
        deviceId: till.deviceId,
        cashierId: 'sara',
        lines: [OrderLine(productId: 2, name: 'Item 2', quantity: 1, unitPrice: 30)],
      );
      till.orders.save(stray, announce: false);

      till.session().current;

      expect(till.orders.byUuid(stray.uuid)?.state, OrderState.held);
      expect(till.orders.held().map((o) => o.uuid), contains(stray.uuid));
    });

    test('recalling a tab from an empty seated claim frees that table', () {
      final sara = till.session();
      till.ring(sara, lines: 1);
      final tab = sara.current.uuid;
      sara.hold(table: 'T1');
      sara.current.tableLabel = 'T9';
      till.orders.save(sara.current, announce: false);
      final claim = sara.current.uuid;

      expect(sara.recall(tab), isTrue);

      expect(till.orders.byUuid(claim), isNull,
          reason: 'the empty claim keeps T9 busy on every till');
    });
  });

  group('M4 · a sale that did not arrive is never counted as sent', () {
    test('refused sales, mirror copies and driver bags are counted apart', () async {
      for (final kind in ['order.push', 'dishflow.sale.push', 'dishflow.driver.order.push']) {
        await till.outboxStore.append(kind, 'u-$kind', {'k': kind});
      }
      await till.outboxStore.append('audit.push', 'audit-1', {});
      expect(till.outboxStore.pendingDishflowCount, 2,
          reason: 'a driver bag waiting to go out must show on the badge');

      for (final e in await till.outboxStore.pending()) {
        await till.outboxStore.markDead(e.id, '403');
      }

      expect(till.outboxStore.pendingCount, 0);
      expect(till.outboxStore.refusedCount, 3,
          reason: 'refused rows leave the pending count without being delivered');
    });

    test('a queue write that fails is written to the audit log', () async {
      final s = PosSession(
        catalogue: CatalogueStore(till.db),
        orders: till.orders,
        outbox: Outbox(store: _RefusingStore(), senders: {}),
        audit: till.audit,
        deviceId: till.deviceId,
        cashierId: 'sara',
      );
      till.ring(s, lines: 1);

      final sale = till.payCash(s);
      await Future<void>.delayed(Duration.zero);

      expect(till.orders.byUuid(sale.uuid)?.state, OrderState.paid);
      expect(till.audit.events(), contains('outbox.enqueue.failed'));
    });

    test('the sale and its queue row are written as one', () {
      final sale = till.payCash(till.session()..addProduct(StressTill.products.first));

      expect(till.orders.byUuid(sale.uuid)?.state, OrderState.paid);
      expect(till.outboxStore.pendingSalesCount, 1);
      expect(till.db.raw.autocommit, isTrue, reason: 'the transaction was left open');
    });
  });

  group('C6 · refunds do not go to Odoo, and do not hang the close', () {
    Order refundOf(Order sale) => Order(
          deviceId: till.deviceId,
          cashierId: 'sara',
          lines: [OrderLine(productId: 1, name: 'Item 1', quantity: -1, unitPrice: 25)],
        )
          ..refundOfUuid = sale.uuid
          ..state = OrderState.paid;

    test('a refund is never owed to Odoo, in or out of the shift', () {
      final s = till.session();
      till.ring(s, lines: 1);
      final sale = till.payCash(s);
      till.orders.save(refundOf(sale), announce: false);

      final shift = till.shifts.currentOpenShift()!;
      expect(till.orders.awaitingSync().map((o) => o.uuid), [sale.uuid]);
      expect(till.orders.awaitingSyncInShift(shift).map((o) => o.uuid), [sale.uuid],
          reason: 'the close would count the refund as synced and arm a retry for it');
    });

    test('refund pushes queued before the change are closed out', () async {
      await till.outboxStore.append('order.push', 'r-1', {'refund_of_uuid': 's-1'});
      await till.outboxStore.append('order.push', 's-2', {'uuid': 's-2'});

      expect(till.outboxStore.retireRefundPushes(), 1);
      expect(till.outboxStore.pendingSalesCount, 1,
          reason: 'only the real sale is still owed');
    });
  });

  group('C5 · a sale books on the day the money came in', () {
    Order seated(DateTime opened) => Order(
          deviceId: till.deviceId,
          cashierId: 'sara',
          createdAt: opened,
          tableLabel: 'T2',
          lines: [OrderLine(productId: 1, name: 'Item 1', quantity: 1, unitPrice: 25)],
        );

    test('a table opened yesterday and paid today books on today', () {
      final opened = DateTime.now().toUtc().subtract(const Duration(hours: 26));
      till.orders.save(seated(opened), announce: false);

      final sale = till.payCash(till.session());

      expect(sale.businessDay, BusinessDay.of(DateTime.now().toUtc()),
          reason: 'the money came in today but the sale books on ${sale.businessDay}');
      expect(till.orders.awaitingSyncInShift(till.shifts.currentOpenShift()!), hasLength(1),
          reason: 'the sale is outside the shift the Odoo close sends');
    });

    test('a clock set back mid-shift still books inside the shift', () {
      final shiftStart = till.shifts.currentOpenShift()!.openedAt;
      final behind = shiftStart.subtract(const Duration(hours: 14));
      final s = till.session(clock: () => behind);
      till.ring(s, lines: 2);

      final sale = till.payCash(s);

      expect(sale.createdAt.isBefore(shiftStart), isFalse,
          reason: 'stamped before the shift opened: outside the Z and the Odoo close');
    });
  });

  group('H2 · an edit queued while the mirror is sending is not lost', () {
    test('the newer payload still goes out after the old send finishes', () async {
      const uuid = 'order-1';
      late Outbox outbox;
      final sent = <Object?>[];
      outbox = Outbox(store: till.outboxStore, senders: {
        'mirror': (entry) async {
          sent.add(entry.payload['rev']);
          if (sent.length == 1) {
            // The cashier re-pays the order while the first send is on the wire.
            await outbox.enqueue('mirror', uuid, {'state': 'paid', 'rev': 2});
          }
        },
      });
      await outbox.enqueue('mirror', uuid, {'state': 'cancelled', 'rev': 1});

      await outbox.drain();
      await outbox.drain();

      expect(sent, [1, 2],
          reason: 'the newer payload was marked sent without ever going out');
      expect(till.outboxStore.pendingCount, 0);
    });

    test('a re-queue with nothing on the wire is still one delivery', () async {
      final sent = <Object?>[];
      final outbox = Outbox(store: till.outboxStore, senders: {
        'mirror': (entry) async => sent.add(entry.payload['rev']),
      });
      await outbox.enqueue('mirror', 'order-2', {'rev': 1});
      await outbox.enqueue('mirror', 'order-2', {'rev': 2});

      await outbox.drain();

      expect(sent, [2]);
    });
  });

  group('M2 · lines never open a second tab on a table another till holds', () {
    test('moving items onto a table busy elsewhere moves nothing', () {
      final other = Order(deviceId: 'till-2', cashierId: 'omar', tableLabel: 'T7')
        ..state = OrderState.held
        ..lines.add(OrderLine(productId: 1, name: 'Soup', quantity: 1, unitPrice: 10));
      till.orders.save(other, announce: false);
      final s = till.session();
      till.ring(s, lines: 3);
      s.hold(table: 'T4');
      s.recall(till.orders.held().single.uuid);

      expect(s.tableBusyElsewhere('T7'), isTrue);
      s.moveLinesToTable({s.current.lines.first.uuid}, 'T7');
      s.moveLinesToTable(s.current.lines.map((l) => l.uuid).toSet(), 'T7');

      final onT7 = till.orders.occupyingAnywhere().where((o) => o.tableLabel == 'T7');
      expect(onT7.map((o) => o.uuid), [other.uuid]);
      expect(s.current.lines, hasLength(3));
      expect(s.current.tableLabel, 'T4');
    });
  });
}
