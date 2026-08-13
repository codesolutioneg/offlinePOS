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

const pizza = Product(id: 10, name: 'Margherita', price: 250);
const cheese = Modifier(id: 1, groupId: 100, name: 'Cheese', price: 7);
const tenPct = Modifier(id: 2, groupId: 100, name: 'Ten Pct', price: 10,
    priceType: ModifierPriceType.percentage);

void main() {
  late Db db;
  late PosSession session;
  late SqliteOutboxStore outboxStore;
  late OrderStore orders;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    outboxStore = SqliteOutboxStore(db);
    orders = OrderStore(db);
    session = PosSession(
      catalogue: CatalogueStore(db),
      orders: orders,
      outbox: Outbox(store: outboxStore, senders: const {}),
      audit: AuditLog(db),
      deviceId: 'till-1',
      cashierId: 'sara',
    );
  });
  tearDown(() => db.close());

  test('adding a product persists it immediately, before any payment', () {
    session.addProduct(pizza);
    expect(orders.drafts().single.lines.single.name, 'Margherita');
  });

  test('splitOffQuantity peels the chosen units onto a new line', () {
    session.addProduct(pizza, qty: 3);
    final line = session.current.lines.single;
    final peeled = session.splitOffQuantity(line.uuid, 1);
    expect(session.current.lines.length, 2);
    final remaining = session.current.lines.firstWhere((l) => l.uuid == line.uuid);
    final taken = session.current.lines.firstWhere((l) => l.uuid == peeled);
    expect(remaining.quantity, 2);
    expect(taken.quantity, 1);
    // Peeled line keeps the product identity so it prices and consolidates the same.
    expect(taken.productId, line.productId);
  });

  test('splitOffQuantity returns the same line when the whole quantity is taken', () {
    session.addProduct(pizza, qty: 2);
    final line = session.current.lines.single;
    final resolved = session.splitOffQuantity(line.uuid, 2);
    expect(resolved, line.uuid);
    expect(session.current.lines.length, 1);
  });

  test('startFresh discards an empty draft rather than leaving it behind', () {
    // An empty order that has been persisted (e.g. a type was set) then a fresh
    // start: the old empty draft must not linger to be restored later.
    session.setOrderType(OrderType.delivery);
    final staleUuid = session.current.uuid;
    expect(orders.drafts().length, 1);

    session.startFresh(OrderType.takeaway);
    expect(session.current.type, OrderType.takeaway);
    expect(session.current.uuid, isNot(staleUuid));
    // Still exactly one draft: the empty one was dropped, not duplicated.
    expect(orders.drafts().length, 1);
    expect(orders.drafts().any((o) => o.uuid == staleUuid), isFalse);
  });

  test('startFresh parks a non-empty order before starting a new one', () {
    session.addProduct(pizza);
    final held = session.current.uuid;
    session.startFresh(OrderType.takeaway);
    // The order with lines is kept (held), and a new empty order is current.
    expect(session.current.uuid, isNot(held));
    expect(orders.held().any((o) => o.uuid == held), isTrue);
  });

  test('a percentage modifier is charged against the parent price', () {
    session.addProduct(pizza, chosen: const [ChosenModifier(tenPct)]);
    expect(session.total, 275);
  });

  test('a fixed modifier adds its own amount', () {
    session.addProduct(pizza, chosen: const [ChosenModifier(cheese)]);
    expect(session.total, 257);
  });

  test('modifiers scale with the line quantity', () {
    session.addProduct(pizza, chosen: const [ChosenModifier(cheese)], qty: 2);
    expect(session.total, 514);
  });

  test('adding the same product again consolidates onto one line', () {
    session.addProduct(pizza);
    session.addProduct(pizza);
    expect(session.current.lines.single.quantity, 2);
    expect(session.total, 500);
  });

  test('identical products with the same modifiers consolidate', () {
    session.addProduct(pizza, chosen: const [ChosenModifier(cheese)]);
    session.addProduct(pizza, chosen: const [ChosenModifier(cheese)]);
    expect(session.current.lines.single.quantity, 2);
    expect(session.total, 2 * (250 + 7));
  });

  test('different modifiers keep the products on separate lines', () {
    session.addProduct(pizza, chosen: const [ChosenModifier(cheese)]);
    session.addProduct(pizza, chosen: const [ChosenModifier(tenPct)]);
    expect(session.current.lines.length, 2);
    expect(session.total, 250 + 7 + 250 + 25);
  });

  test('a line already sent to the kitchen is not merged into by a new add', () {
    session.addProduct(pizza);
    session.current.lines.single.printedToKitchen = true;
    session.addProduct(pizza);
    expect(session.current.lines.length, 2);
  });

  test('a seat-tagged line is not merged into, so split maths stays intact', () {
    session.addProduct(pizza);
    session.setLineSeat(session.current.lines.single.uuid, 1);
    session.addProduct(pizza);
    expect(session.current.lines.length, 2);
  });

  test('splitting a consolidated line explodes it into single-unit lines', () {
    session.addProduct(pizza);
    session.addProduct(pizza);
    session.addProduct(pizza); // one line, qty 3
    session.splitLineToUnits(session.current.lines.single.uuid);
    expect(session.current.lines.length, 3);
    expect(session.current.lines.every((l) => l.quantity == 1), isTrue);
    expect(session.total, 750);
  });

  test('assigning a guest to a consolidated line peels one unit onto that guest', () {
    session.addProduct(pizza);
    session.addProduct(pizza); // consolidated -> one line, qty 2
    expect(session.current.lines.single.quantity, 2);
    session.setLineSeat(session.current.lines.single.uuid, 1);
    // Now two lines: one unit on guest 1, one still unassigned.
    expect(session.current.lines.length, 2);
    final guest1 = session.current.lines.firstWhere((l) => l.seat == 1);
    final rest = session.current.lines.firstWhere((l) => l.seat == null);
    expect(guest1.quantity, 1);
    expect(rest.quantity, 1);
    expect(session.total, 500); // value unchanged by the split
  });

  test('setting quantity to zero removes the line', () {
    session.addProduct(pizza);
    session.setQuantity(session.current.lines.single.uuid, 0);
    expect(session.hasLines, isFalse);
  });

  test('payment queues the order and hands back a fresh one', () {
    session.addProduct(pizza);
    final uuid = session.current.uuid;
    final paid = session.pay();
    expect(paid.state, OrderState.paid);
    expect(outboxStore.pendingCount, 1);
    expect(session.current.uuid, isNot(uuid));
    expect(session.hasLines, isFalse);
  });

  test('payment is auditable even with no server', () {
    session.addProduct(pizza);
    session.pay();
    expect(AuditLog(db).unsynced().single['event'], 'order.paid');
  });

  test('an unfinished order is restored, which is what survives a crash', () {
    session.addProduct(pizza, chosen: const [ChosenModifier(cheese)]);
    final uuid = session.current.uuid;
    final revived = PosSession(
      catalogue: CatalogueStore(db), orders: orders,
      outbox: Outbox(store: outboxStore, senders: const {}),
      audit: AuditLog(db), deviceId: 'till-1', cashierId: 'sara',
    );
    expect(revived.current.uuid, uuid);
    expect(revived.total, 257);
  });
}
