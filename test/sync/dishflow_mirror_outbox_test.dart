import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/app/pos_session.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/db/shift_store.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/sync/dishflow_mirror.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/core/sync/sync_service.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/domain/order.dart';

import '../db/sqlite_loader.dart';

const burger = Product(id: 10, name: 'Burger', price: 50);

void main() {
  late Db db;
  late SqliteOutboxStore store;
  late Outbox outbox;
  late SettingsStore settings;
  late PosSession session;

  setUpAll(useSystemSqlite);

  setUp(() {
    db = Db.open(':memory:');
    store = SqliteOutboxStore(db);
    outbox = Outbox(store: store, senders: {});
    settings = SettingsStore(db);
    session = PosSession(
      catalogue: CatalogueStore(db),
      orders: OrderStore(db),
      outbox: outbox,
      audit: AuditLog(db),
      deviceId: 'till1',
      cashierId: 'c1',
      settings: settings,
      nextOrderNo: () => '1508-0001-T01',
    );
  });

  tearDown(() => db.close());

  test('pay does not enqueue dishflow when mirror is off', () {
    session.addProduct(burger);
    session.pay(payments: const [
      OrderPayment(methodId: -1, amount: 50, label: 'Cash'),
    ]);
    expect(store.pendingSalesCount, 1);
    expect(store.pendingDishflowCount, 0);
  });

  test('pay enqueues dishflow.sale.push when mirror is ready', () async {
    settings.dishflowMirrorEnabled = true;
    settings.dishflowProjectId = 'odc-chat';
    settings.dishflowApiKey = 'key';
    settings.dishflowOdooConnectionId = 'conn1';
    session.addProduct(burger);
    final paid = session.pay(payments: const [
      OrderPayment(methodId: -1, amount: 50, label: 'Cash'),
    ])!;
    await Future<void>.delayed(Duration.zero);
    expect(store.pendingSalesCount, 1);
    expect(store.pendingDishflowCount, 1);
    final pending = await store.pending(kinds: {DishflowMirror.kind});
    expect(pending.single.payloadUuid, paid.uuid);
    expect(pending.single.payload['fields']['source'], 'offline_pos');
  });

  test('kinds drain leaves order.push untouched', () async {
    await outbox.enqueue('order.push', 'o1', {'uuid': 'o1'});
    await outbox.enqueue(DishflowMirror.kind, 'd1', {
      'doc_id': 'x',
      'project_id': 'p',
      'api_key': 'k',
      'fields': {'status': 'sale'},
    });
    var dishflowHits = 0;
    outbox.register(DishflowMirror.kind, (e) async {
      dishflowHits++;
    });
    outbox.register('order.push', (e) async {
      fail('order.push must not drain on the owner-mirror pass');
    });
    final sent = await outbox.drain(kinds: {DishflowMirror.kind});
    expect(sent, 1);
    expect(dishflowHits, 1);
    expect(store.pendingSalesCount, 1);
    expect(store.pendingDishflowCount, 0);
  });

  test('sync pendingToSync counts both queues', () async {
    await outbox.enqueue('order.push', 'o1', {'uuid': 'o1'});
    await outbox.enqueue(DishflowMirror.kind, 'd1', {'doc_id': 'x'});
    final sync = SyncService(
      outbox: outbox,
      catalogue: CatalogueStore(db),
      outboxStore: store,
      deviceId: 'till1',
      appVersion: 'test',
    );
    expect(sync.pendingSales, 1);
    expect(sync.pendingDishflow, 1);
    expect(sync.pendingToSync, 2);
  });

  test('enqueueCancelIfEnabled writes status cancelled on the same uuid', () async {
    settings.dishflowMirrorEnabled = true;
    settings.dishflowProjectId = 'odc-chat';
    settings.dishflowApiKey = 'key';
    settings.dishflowOdooConnectionId = 'conn1';
    session.addProduct(burger);
    final paid = session.pay(payments: const [
      OrderPayment(methodId: -1, amount: 50, label: 'Cash'),
    ])!;
    await Future<void>.delayed(Duration.zero);
    expect(store.pendingDishflowCount, 1);

    await DishflowMirror.enqueueCancelIfEnabled(
      outbox: outbox,
      settings: settings,
      order: paid,
    );
    final pending = await store.pending(kinds: {DishflowMirror.kind});
    // Same (kind, uuid) upserts — cancel replaces the queued sale payload.
    expect(pending, hasLength(1));
    expect(pending.single.payloadUuid, paid.uuid);
    expect(pending.single.payload['fields']['status'], 'cancelled');
  });

  group('resend open shift', () {
    late ShiftStore shifts;
    late OrderStore orders;

    void configure() {
      settings.dishflowMirrorEnabled = true;
      settings.dishflowProjectId = 'odc-chat';
      settings.dishflowApiKey = 'key';
      settings.dishflowOdooConnectionId = 'conn1';
    }

    Order sell() {
      session.addProduct(burger);
      return session.pay(payments: const [
        OrderPayment(methodId: -1, amount: 50, label: 'Cash'),
      ])!;
    }

    DishflowResendPlan plan() => DishflowMirror.planOpenShift(
        shift: shifts.currentOpenShift(), orders: orders, store: store);

    setUp(() {
      shifts = ShiftStore(db);
      orders = OrderStore(db);
      shifts.openShift(
        openingFloat: 0,
        cashierId: 'c1',
        at: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
      );
    });

    test('queues sales paid before the mirror was configured', () async {
      final early = sell();
      await Future<void>.delayed(Duration.zero);
      expect(store.pendingDishflowCount, 0);

      configure();
      final p = plan();
      expect(p.shiftOpen, isTrue);
      expect(p.toSend.map((o) => o.uuid), [early.uuid]);

      final queued = await DishflowMirror.resend(
          outbox: outbox, store: store, settings: settings, plan: p);
      expect(queued, 1);
      final pending = await store.pending(kinds: {DishflowMirror.kind});
      expect(pending.single.payloadUuid, early.uuid);
      expect(pending.single.payload['fields']['status'], 'sale');
    });

    test('skips sent and waiting sales, retries refused ones', () async {
      configure();
      final sent = sell();
      final waiting = sell();
      final refused = sell();
      await Future<void>.delayed(Duration.zero);
      final rows = await store.pending(kinds: {DishflowMirror.kind});
      int idOf(Order o) => rows.firstWhere((r) => r.payloadUuid == o.uuid).id;
      await store.markSent(idOf(sent));
      await store.markDead(idOf(refused), 'PERMISSION_DENIED');

      final p = plan();
      expect(p.total, 3);
      expect(p.sent, 1);
      expect(p.waiting, 1);
      expect(p.refused, 1);
      expect(p.toSend.map((o) => o.uuid), [refused.uuid]);

      await DishflowMirror.resend(
          outbox: outbox, store: store, settings: settings, plan: p);
      final pending = await store.pending(kinds: {DishflowMirror.kind});
      expect(pending.map((e) => e.payloadUuid).toSet(),
          {waiting.uuid, refused.uuid});
    });

    test('the primary also sends the other tills\' sales', () async {
      configure();
      final mine = sell();
      await Future<void>.delayed(Duration.zero);
      final rows = await store.pending(kinds: {DishflowMirror.kind});
      await store.markSent(rows.single.id);
      final theirs = Order(
        deviceId: 'till2',
        cashierId: 'c2',
        state: OrderState.paid,
        orderNo: '1508-0002-T02',
      );
      OrderStore(db).save(theirs, announce: false);

      final own = OrderStore(db, ownDeviceId: 'till1');
      final single = DishflowMirror.planOpenShift(
          shift: shifts.currentOpenShift(), orders: own, store: store);
      expect(single.toSend, isEmpty);
      expect(single.sent, 1);

      final primary = DishflowMirror.planOpenShift(
          shift: shifts.currentOpenShift(),
          orders: own,
          store: store,
          allTills: true);
      expect(primary.otherTills, 1);
      expect(primary.toSend.map((o) => o.uuid), [theirs.uuid]);
      expect(primary.total, 2);

      await DishflowMirror.resend(
          outbox: outbox, store: store, settings: settings, plan: primary);
      final pending = await store.pending(kinds: {DishflowMirror.kind});
      expect(pending.single.payloadUuid, theirs.uuid);
      expect(pending.single.payload['doc_id'], contains('offlinepos_till2'));
      expect(mine.deviceId, 'till1');
    });

    test('nothing to do without an open shift', () async {
      configure();
      shifts.closeShift(countedCash: 0);
      expect(plan().shiftOpen, isFalse);
    });

    test('resend does nothing while the mirror is not ready', () async {
      sell();
      final p = plan();
      expect(p.toSend, hasLength(1));
      final queued = await DishflowMirror.resend(
          outbox: outbox, store: store, settings: settings, plan: p);
      expect(queued, 0);
      expect(store.pendingDishflowCount, 0);
    });
  });
}
