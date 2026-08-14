import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/app/pos_session.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/domain/order.dart';

import '../db/sqlite_loader.dart';

const pizza = Product(id: 10, name: 'Margherita', price: 100);

void main() {
  late Db db;
  late SettingsStore settings;
  late OrderStore orders;
  late PosSession session;

  // The session reads the shop's rule through the same resolver the app wires up, so
  // these tests exercise the real stamping path rather than a hand-set percentage.
  PosSession openSession() => PosSession(
        catalogue: CatalogueStore(db),
        orders: orders,
        outbox: Outbox(store: SqliteOutboxStore(db), senders: const {}),
        audit: AuditLog(db),
        deviceId: 'till-1',
        cashierId: 'sara',
        serviceChargeFor: settings.serviceChargePercentFor,
      );

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    settings = SettingsStore(db);
    settings.serviceChargePercent = 12;
    orders = OrderStore(db);
    session = openSession();
  });
  tearDown(() => db.close());

  test('a dine-in bill is charged and a takeaway one is not', () {
    session.setOrderType(OrderType.dineIn);
    session.addProduct(pizza, qty: 2);
    expect(session.current.serviceChargePercent, 12);
    expect(session.current.total, 224);

    session.setOrderType(OrderType.takeaway);
    expect(session.current.serviceChargePercent, 0);
    expect(session.current.total, 200);
  });

  test('delivery is charged only once the shop says so', () {
    session.setOrderType(OrderType.delivery);
    session.addProduct(pizza);
    expect(session.current.serviceChargePercent, 0);
    settings.setServiceChargeOrderType(OrderType.delivery, true);
    // Still 0: the bill keeps its stamp. Only re-opening the type re-resolves it.
    expect(session.current.serviceChargePercent, 0);
    session.setOrderType(OrderType.delivery);
    expect(session.current.serviceChargePercent, 12);
  });

  test('a session with no resolver charges nothing at all', () {
    final plain = PosSession(
      catalogue: CatalogueStore(db),
      orders: orders,
      outbox: Outbox(store: SqliteOutboxStore(db), senders: const {}),
      audit: AuditLog(db),
      deviceId: 'till-1',
      cashierId: 'sara',
    );
    plain.addProduct(pizza);
    expect(plain.current.serviceChargePercent, 0);
    expect(plain.current.total, 100);
  });

  test('a running bill keeps its charge when a manager edits the setting', () {
    session.addProduct(pizza, qty: 2);
    final before = session.current.total;
    settings.serviceChargePercent = 20;
    expect(session.current.total, before);
    expect(session.current.serviceChargePercent, 12);
  });

  test('a bill parked and recalled keeps the charge it was opened with', () {
    session.addProduct(pizza, qty: 2);
    final uuid = session.current.uuid;
    session.hold(table: 'T1');
    settings.serviceChargePercent = 25;

    // A restart is the honest version of this: a brand-new session over the same disk.
    final later = openSession();
    later.recall(uuid);
    expect(later.current.serviceChargePercent, 12);
    expect(later.current.total, 224);
    // The new bill that session opens does take the new rule.
    later.newOrder();
    expect(later.current.serviceChargePercent, 25);
  });

  test('a restored draft keeps its stamp, and a fresh order takes the new rule', () {
    session.addProduct(pizza);
    settings.serviceChargePercent = 30;
    final later = openSession();
    expect(later.current.serviceChargePercent, 12);
    later.startFresh(OrderType.dineIn);
    expect(later.current.serviceChargePercent, 30);
  });

  test('clearing a bill re-stamps it, since it is a fresh bill on the same row', () {
    session.addProduct(pizza);
    settings.serviceChargePercent = 15;
    session.clear();
    session.addProduct(pizza);
    expect(session.current.serviceChargePercent, 15);
  });

  test('a paid order carries the charge into the outbox payload', () {
    session.addProduct(pizza, qty: 2);
    final paid = session.pay(
        payments: [const OrderPayment(methodId: 1, amount: 224, label: 'Cash')]);
    expect(paid.total, 224);
    final sent = paid.toServerPayload();
    final line = (sent['lines'] as List).single as Map;
    expect(line['unit_price'], closeTo(112, 0.0001));
  });

  test('an even-split share pays down a balance that includes the charge', () {
    session.addProduct(pizza, qty: 2);
    final left = session.payShare(
        payments: [const OrderPayment(methodId: 1, amount: 112, label: 'Cash')]);
    expect(left, closeTo(112, 0.0001));
    final done = session.payShare(
        payments: [const OrderPayment(methodId: 1, amount: 112, label: 'Cash')]);
    expect(done, 0);
  });

  test('split checks add up to exactly what the table was charged', () {
    session.setOrderType(OrderType.dineIn);
    session.addProduct(pizza);
    session.addProduct(const Product(id: 11, name: 'Pasta', price: 50));
    final tableTotal = session.current.total; // 150 + 12% = 168
    final first = session.current.lines.first.uuid;
    final second = session.current.lines.last.uuid;

    final checkA = session.payCheck([first]);
    // The setting moving mid-service must not shift the second check's share.
    settings.serviceChargePercent = 50;
    final checkB = session.payCheck([second]);

    expect(checkA.serviceChargePercent, 12);
    expect(checkB.serviceChargePercent, 12);
    expect(checkA.total + checkB.total, closeTo(tableTotal, 0.0001));
  });

  test('a check quotes the same figure it books, service included', () {
    // What the tender sheet asks for has to be what payCheck charges, or a split guest
    // pays the food and the table quietly eats the service.
    session.setOrderType(OrderType.dineIn);
    session.addProduct(pizza);
    session.addProduct(const Product(id: 11, name: 'Pasta', price: 50));
    session.setDiscount(10);
    final picked = [session.current.lines.first];
    final quoted = session.checkTotal(picked);
    expect(quoted, closeTo(100 * 0.9 * 1.12, 0.0001));

    final check = session.payCheck([picked.single.uuid]);
    expect(check.total, closeTo(quoted, 0.0001));
  });

  test('lines moved to a new table keep the price they were rung at', () {
    session.setOrderType(OrderType.dineIn);
    session.setTable('T1');
    session.addProduct(pizza, qty: 2);
    final moved = session.current.lines.single.uuid;
    settings.serviceChargePercent = 50;

    final target = session.moveLinesToTable({moved}, 'T2');
    expect(target.serviceChargePercent, 12);
    expect(target.total, 224);
  });

  test('a merged table bills one service percentage, its own', () {
    session.setOrderType(OrderType.dineIn);
    session.setTable('T1');
    session.addProduct(pizza);
    session.hold(table: 'T1');
    final source = orders.held().single.uuid;

    session.setTable('T2');
    session.addProduct(pizza);
    session.mergeOrderInto(source);
    expect(session.current.lines.length, 2);
    expect(session.current.serviceChargePercent, 12);
    expect(session.current.total, 224);
  });

  test('the charge costs a sale nothing: no queue is drained by ringing one', () {
    // The offline drill. Stamping is a local field write, so a serviced sale enqueues
    // exactly what an unserviced one does and waits on nothing.
    session.addProduct(pizza);
    session.pay(payments: [const OrderPayment(methodId: 1, amount: 112)]);
    expect(orders.awaitingSync().single.serviceChargePercent, 12);
  });
}
