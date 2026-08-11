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

const pizza = Product(id: 10, name: 'Pizza', price: 100);
const cola = Product(id: 11, name: 'Cola', price: 20);
const cake = Product(id: 12, name: 'Cake', price: 40);

void main() {
  late Db db;
  late PosSession session;
  late OrderStore orders;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    orders = OrderStore(db);
    session = PosSession(
      catalogue: CatalogueStore(db),
      orders: orders,
      outbox: Outbox(store: SqliteOutboxStore(db), senders: const {}),
      audit: AuditLog(db),
      deviceId: 'till-1',
      cashierId: 'sara',
    );
  });
  tearDown(() => db.close());

  String lineFor(int productId) =>
      session.current.lines.firstWhere((l) => l.productId == productId).uuid;

  group('seats', () {
    test('a line can be tagged to a guest and listed in seatsInUse', () {
      session.addProduct(pizza);
      session.addProduct(cola);
      session.setLineSeat(lineFor(10), 1);
      session.setLineSeat(lineFor(11), 2);
      expect(session.seatsInUse, [1, 2]);
    });

    test('a zero or negative seat clears the tag', () {
      session.addProduct(pizza);
      session.setLineSeat(lineFor(10), 0);
      expect(session.current.lines.single.seat, isNull);
      expect(session.seatsInUse, isEmpty);
    });
  });

  group('payCheck (split bill)', () {
    test('paying a subset settles a check and leaves the rest open', () {
      session.setTable('12');
      session.addProduct(pizza); // 100
      session.addProduct(cola); // 20
      final pizzaLine = lineFor(10);

      final check = session.payCheck([pizzaLine],
          payments: const [OrderPayment(methodId: 1, amount: 100, label: 'Cash')]);

      expect(check.state, OrderState.paid);
      expect(check.total, 100);
      expect(check.tableLabel, '12');
      expect(orders.awaitingSync().single.uuid, check.uuid);
      // The cola is still open on the table.
      expect(session.current.lines.single.productId, 11);
      expect(session.total, 20);
    });

    test('paying the last lines closes the table and starts a fresh order', () {
      session.addProduct(pizza);
      final only = lineFor(10);
      final firstUuid = session.current.uuid;

      session.payCheck([only],
          payments: const [OrderPayment(methodId: 1, amount: 100)]);

      expect(orders.byUuid(firstUuid), isNull); // the emptied order is gone
      expect(session.hasLines, isFalse);
      expect(orders.awaitingSync(), hasLength(1));
    });

    test('two guest checks produce two independent paid orders', () {
      session.addProduct(pizza);
      session.addProduct(cola);
      session.addProduct(cake);
      session.setLineSeat(lineFor(10), 1);
      session.setLineSeat(lineFor(11), 1);
      session.setLineSeat(lineFor(12), 2);

      final guest1 =
          session.current.lines.where((l) => l.seat == 1).map((l) => l.uuid).toList();
      session.payCheck(guest1,
          payments: const [OrderPayment(methodId: 1, amount: 120)]);
      expect(session.total, 40); // guest 2's cake remains

      final guest2 = session.current.lines.map((l) => l.uuid).toList();
      session.payCheck(guest2,
          payments: const [OrderPayment(methodId: 2, amount: 40)]);

      expect(orders.awaitingSync(), hasLength(2));
      expect(session.hasLines, isFalse);
    });
  });

  group('move & merge', () {
    test('moving lines to another table opens a tab there and trims here', () {
      session.setTable('1');
      session.addProduct(pizza);
      session.addProduct(cola);
      final move = {lineFor(11)};

      final target = session.moveLinesToTable(move, '2');

      expect(target.tableLabel, '2');
      expect(target.lines.single.productId, 11);
      expect(session.current.lines.single.productId, 10); // pizza stays on table 1
    });

    test('merging another order folds its lines in and discards the source', () {
      // Park an order on table 2.
      session.setTable('2');
      session.addProduct(cola);
      session.hold();
      final held = orders.held().single;

      // Now on a fresh order on table 1, merge table 2 in.
      session.setTable('1');
      session.addProduct(pizza);
      session.mergeOrderInto(held.uuid);

      expect(orders.byUuid(held.uuid), isNull);
      expect(session.current.lines.map((l) => l.productId).toSet(), {10, 11});
    });
  });
}
