import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/app/pos_session.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/settings_store.dart';
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
    ]);
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
}
