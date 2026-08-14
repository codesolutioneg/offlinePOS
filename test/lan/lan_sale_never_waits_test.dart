import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/app/pos_session.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/domain/order.dart';

import '../db/sqlite_loader.dart';
import 'shop.dart';

const _pizza = Product(id: 1, name: 'Pizza', price: 100);

/// A sale rung and tendered the way the sell screen does it: synchronously, with
/// nothing awaited.
Order ringUpAndPay(PosSession session) {
  session.addProduct(_pizza);
  return session.pay(payments: const [OrderPayment(methodId: 1, amount: 100)]);
}

PosSession sessionOn(Db db, OrderStore orders, {required String deviceId}) =>
    PosSession(
      catalogue: CatalogueStore(db),
      orders: orders,
      outbox: Outbox(store: SqliteOutboxStore(db), senders: {}),
      audit: AuditLog(db),
      deviceId: deviceId,
      cashierId: 'ana',
    );

void main() {
  setUpAll(useSystemSqlite);

  test('with the fabric off, a sale writes exactly what it always wrote', () {
    final db = Db.open(':memory:');
    addTearDown(db.close);
    // No publish wired: this is a one-till shop, or a till with the flag off.
    final orders = OrderStore(db);
    final sale = ringUpAndPay(sessionOn(db, orders, deviceId: 'till-a'));

    expect(orders.byUuid(sale.uuid)!.state, OrderState.paid);
    expect(SqliteOutboxStore(db).pendingCount, 1);
    // Not one row of fabric bookkeeping, and not one socket.
    expect(db.raw.select('SELECT COUNT(*) c FROM lan_events').first['c'], 0);
  });

  test('a sale completes with the fabric on and nobody else on the LAN', () async {
    final shop = TestShop();
    addTearDown(shop.close);
    final a = shop.add('till-a');

    final sale = ringUpAndPay(sessionOn(a.db, a.orders, deviceId: 'till-a'));

    expect(a.orders.byUuid(sale.uuid)!.state, OrderState.paid);
    expect(a.log.since(0).single.recordUuid, sale.uuid);
    // A pass with no peers is silent, not an error.
    await a.fabric.pass();
    expect(a.errors, isEmpty);
  });

  test('a peer that throws cannot touch the sale', () async {
    final shop = TestShop();
    addTearDown(shop.close);
    final a = shop.add('till-a');
    shop.add('till-b');
    shop.introduceAll();
    shop.throwing.add('till-b');

    final sale = ringUpAndPay(sessionOn(a.db, a.orders, deviceId: 'till-a'));

    // The money is booked and queued before the fabric has done anything at all.
    expect(a.orders.byUuid(sale.uuid)!.state, OrderState.paid);
    expect(a.orders.awaitingSync().single.uuid, sale.uuid);

    await a.fabric.pass();
    // The broken peer is recorded, and it changed nothing about the sale.
    expect(a.errors, isNotEmpty);
    expect(a.orders.byUuid(sale.uuid)!.state, OrderState.paid);
    expect(a.log.since(0).single.recordUuid, sale.uuid);
  });

  test('a fabric that cannot even record the change still takes the money', () {
    final db = Db.open(':memory:');
    addTearDown(db.close);
    final failures = <String>[];
    final orders = OrderStore(
      db,
      ownDeviceId: 'till-a',
      publish: (kind, uuid, payload) => throw StateError('the log is broken'),
      onAnnounceFailed: (uuid, error) => failures.add('$uuid: $error'),
    );

    final sale = ringUpAndPay(sessionOn(db, orders, deviceId: 'till-a'));

    // The sale outranks replication: the order is committed on its own and the
    // failure is reported rather than swallowed or thrown at the cashier.
    expect(orders.byUuid(sale.uuid)!.state, OrderState.paid);
    expect(orders.awaitingSync().single.uuid, sale.uuid);
    expect(failures.single, contains(sale.uuid));
  });
}
