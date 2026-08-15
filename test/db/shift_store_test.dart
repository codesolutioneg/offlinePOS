import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/schema.dart';
import 'package:offline_pos/core/db/shift_store.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:sqlite3/sqlite3.dart';
import 'sqlite_loader.dart';

void main() {
  setUpAll(useSystemSqlite);
  late Db db;
  late ShiftStore shifts;
  late OrderStore orders;
  setUp(() {
    db = Db.open(':memory:');
    shifts = ShiftStore(db);
    orders = OrderStore(db);
  });
  tearDown(() => db.close());

  OrderLine line(double p) => OrderLine(productId: 1, name: 'x', quantity: 1, unitPrice: p);

  test('open, record movements, close, and persist across a reopen', () {
    final s = shifts.openShift(openingFloat: 100, cashierId: 'c1');
    expect(shifts.currentOpenShift()!.id, s.id);
    shifts.addMovement('in', 50, reason: 'topup');
    shifts.addMovement('out', 20, reason: 'petty');
    final reread = ShiftStore(db).currentOpenShift()!;
    expect(reread.cashIn, 50);
    expect(reread.cashOut, 20);
    // The reason round-trips through storage, so a paid-in/out stays auditable.
    expect(reread.movements.map((m) => m.reason), ['topup', 'petty']);
    final closed = shifts.closeShift(countedCash: 130);
    expect(closed.isOpen, isFalse);
    expect(shifts.currentOpenShift(), isNull);
  });

  test('a paid-out carries an expense category that round-trips through storage', () {
    shifts.openShift(openingFloat: 100, cashierId: 'c1');
    shifts.addMovement('out', 30, reason: 'taxi', category: 'Transport');
    final reread = ShiftStore(db).currentOpenShift()!;
    final out = reread.movements.single;
    expect(out.category, 'Transport');
    expect(out.reason, 'taxi');
  });

  test('only one shift can be open at a time', () {
    shifts.openShift(openingFloat: 0, cashierId: 'c1');
    expect(() => shifts.openShift(openingFloat: 0, cashierId: 'c1'), throwsStateError);
  });

  test('X/Z summary counts window sales, expected cash, and variance', () {
    shifts.openShift(openingFloat: 100, cashierId: 'c1');
    orders.save(Order(deviceId: 'd', cashierId: 'c1')
      ..lines.add(line(40))
      ..state = OrderState.paid);
    shifts.addMovement('in', 10);
    shifts.addMovement('out', 5);
    final sum = shifts.summary(shifts.currentOpenShift()!);
    expect(sum.salesCount, 1);
    expect(sum.salesTotal, 40);
    expect(sum.expectedCash, 145); // 100 + 40 + 10 - 5
    final closed = shifts.closeShift(countedCash: 145);
    expect(shifts.summary(closed).variance, 0);
  });

  test('card sales are takings but not drawer cash', () {
    shifts.openShift(openingFloat: 100, cashierId: 'c1');
    // A cash sale, tendered to the cash method (id 1).
    orders.save(Order(deviceId: 'd', cashierId: 'c1')
      ..lines.add(line(40))
      ..payments = [const OrderPayment(methodId: 1, amount: 40)]
      ..state = OrderState.paid);
    // A card sale, tendered to a non-cash method (id 2).
    orders.save(Order(deviceId: 'd', cashierId: 'c1')
      ..lines.add(line(30))
      ..payments = [const OrderPayment(methodId: 2, amount: 30)]
      ..state = OrderState.paid);
    final sum = shifts.summary(shifts.currentOpenShift()!, cashMethodIds: {1});
    expect(sum.salesCount, 2);
    expect(sum.salesTotal, 70); // turnover across both tenders
    expect(sum.cashSales, 40); // only the cash sale reaches the drawer
    expect(sum.expectedCash, 140); // 100 float + 40 cash
  });

  test('a new shift carries an identity that round-trips through storage', () {
    final s = shifts.openShift(openingFloat: 0, cashierId: 'c1');
    expect(s.uuid, isNotEmpty);
    expect(ShiftStore(db).currentOpenShift()!.uuid, s.uuid);
  });

  test('a v13 till keeps its shifts through the upgrade and has no null uuid', () {
    // Built the way a shipped v13 till was built, then upgraded. A shift holds the
    // drawer count for the day, so losing one loses the reconciliation with it.
    const v13 = 13;
    final raw = sqlite3.open(':memory:');
    for (var v = 0; v < v13; v++) {
      for (final statement in Schema.migrations[v]) {
        raw.execute(statement);
      }
    }
    raw.execute('PRAGMA user_version = $v13');
    raw.execute(
      'INSERT INTO shifts (id, opened_at, opening_float, cashier_id, movements) '
      "VALUES ('SH1', '2026-03-01T08:00:00Z', 100, 'c1', '[]')",
    );

    final upgraded = Db(raw)..migrate();
    addTearDown(upgraded.close);

    expect(upgraded.userVersion, Schema.version);
    final open = ShiftStore(upgraded).currentOpenShift()!;
    expect(open.id, 'SH1');
    expect(open.openingFloat, 100);
    // Derived from the id the row already had, so the backfill is the same value on
    // every till that upgrades and cannot leave a null behind.
    expect(upgraded.raw.select('SELECT uuid FROM shifts').single['uuid'], 'SH1');
    expect(open.uuid, 'SH1');
  });

  test('per-tender totals cover a mixed window and a split tender', () {
    shifts.openShift(openingFloat: 100, cashierId: 'c1');
    orders.save(Order(deviceId: 'd', cashierId: 'c1')
      ..lines.add(line(40))
      ..payments = [const OrderPayment(methodId: 1, amount: 40, label: 'Cash')]
      ..state = OrderState.paid);
    orders.save(Order(deviceId: 'd', cashierId: 'c1')
      ..lines.add(line(30))
      ..payments = [const OrderPayment(methodId: 2, amount: 30, label: 'Visa')]
      ..state = OrderState.paid);
    // One sale settled on two tenders: each method takes its own share.
    orders.save(Order(deviceId: 'd', cashierId: 'c1')
      ..lines.add(line(50))
      ..payments = [
        const OrderPayment(methodId: 1, amount: 20, label: 'Cash'),
        const OrderPayment(methodId: 2, amount: 30, label: 'Visa'),
      ]
      ..state = OrderState.paid);

    final sum = shifts.summary(shifts.currentOpenShift()!, cashMethodIds: {1});
    // Cash leads, since that is the row the drawer count is checked against.
    expect(sum.tenders.map((t) => (t.label, t.amount, t.isCash)),
        [('Cash', 60.0, true), ('Visa', 60.0, false)]);
    // The cash rows and the drawer figure are the same money read two ways.
    expect(sum.cashSales, 60);
    expect(sum.salesTotal, 120);
    expect(sum.expectedCash, 160); // 100 float + 60 cash, unchanged by the breakdown
  });

  test('a sale with no recorded tender joins the cash row', () {
    shifts.openShift(openingFloat: 0, cashierId: 'c1');
    // No payments at all: an implicit cash sale, the way the server books one.
    orders.save(Order(deviceId: 'd', cashierId: 'c1')
      ..lines.add(line(25))
      ..state = OrderState.paid);
    orders.save(Order(deviceId: 'd', cashierId: 'c1')
      ..lines.add(line(15))
      ..payments = [const OrderPayment(methodId: 1, amount: 15, label: 'Cash')]
      ..state = OrderState.paid);

    final sum = shifts.summary(shifts.currentOpenShift()!, cashMethodIds: {1});
    expect(sum.tenders.single.label, 'Cash');
    expect(sum.tenders.single.amount, 40);
    expect(sum.cashSales, 40);
  });

  test('an unlabelled non-cash tender never joins the cash row', () {
    shifts.openShift(openingFloat: 0, cashierId: 'c1');
    orders.save(Order(deviceId: 'd', cashierId: 'c1')
      ..lines.add(line(25))
      ..state = OrderState.paid);
    // A tender saved before labels were kept: it is named by its method id rather
    // than guessed at, so it cannot be counted against the drawer.
    orders.save(Order(deviceId: 'd', cashierId: 'c1')
      ..lines.add(line(30))
      ..payments = [const OrderPayment(methodId: 2, amount: 30)]
      ..state = OrderState.paid);

    final sum = shifts.summary(shifts.currentOpenShift()!, cashMethodIds: {1});
    expect(sum.tenders.map((t) => t.label), ['Cash', 'Method 2']);
    expect(sum.cashSales, 25);
    expect(sum.tenders.where((t) => t.isCash).fold(0.0, (s, t) => s + t.amount), 25);
  });

  test('a refund in the window reduces the tender it went back on', () {
    shifts.openShift(openingFloat: 100, cashierId: 'c1');
    final sale = Order(deviceId: 'd', cashierId: 'c1')
      ..lines.add(line(60))
      ..payments = [const OrderPayment(methodId: 2, amount: 60, label: 'Visa')]
      ..state = OrderState.paid;
    orders.save(sale);
    // A refund is an order of its own with negative lines and negative tenders, so
    // it nets off the method the money came in on rather than the cash row.
    orders.save(Order(
      deviceId: 'd',
      cashierId: 'c1',
      lines: [OrderLine(productId: 1, name: 'x', quantity: -1, unitPrice: 20)],
      payments: [const OrderPayment(methodId: 2, amount: -20, label: 'Visa')],
    )
      ..refundOfUuid = sale.uuid
      ..state = OrderState.paid);

    final sum = shifts.summary(shifts.currentOpenShift()!, cashMethodIds: {1});
    expect(sum.salesTotal, 40);
    expect(sum.tenders.single.label, 'Visa');
    expect(sum.tenders.single.amount, 40);
    expect(sum.cashSales, 0);
    // The card refund never touched the drawer, so the expected cash is the float.
    expect(sum.expectedCash, 100);
    final closed = shifts.closeShift(countedCash: 100);
    expect(shifts.summary(closed, cashMethodIds: {1}).variance, 0);
  });

  test('the shift splits by cashier and the rows add up to the whole', () {
    shifts.openShift(openingFloat: 100, cashierId: 'c1');
    // Two people sharing one till over a service, which is the whole reason a
    // per-cashier read exists.
    orders.save(Order(deviceId: 'd', cashierId: 'c1')
      ..lines.add(line(40))
      ..payments = [const OrderPayment(methodId: 1, amount: 40, label: 'Cash')]
      ..state = OrderState.paid);
    orders.save(Order(deviceId: 'd', cashierId: 'c2')
      ..lines.add(line(60))
      ..payments = [const OrderPayment(methodId: 2, amount: 60, label: 'Visa')]
      ..state = OrderState.paid);
    orders.save(Order(deviceId: 'd', cashierId: 'c2')
      ..lines.add(line(10))
      ..payments = [const OrderPayment(methodId: 1, amount: 10, label: 'Cash')]
      ..state = OrderState.paid);

    final shift = shifts.currentOpenShift()!;
    final whole = shifts.summary(shift, cashMethodIds: {1});
    final byCashier = shifts.summaryByCashier(shift, cashMethodIds: {1});

    // Biggest taker first, so the busiest cashier is the first row a manager reads.
    expect(byCashier.keys.toList(), ['c2', 'c1']);
    expect(byCashier['c1']!.salesTotal, 40);
    expect(byCashier['c2']!.salesTotal, 70);
    expect(byCashier.values.fold(0.0, (s, e) => s + e.salesTotal), whole.salesTotal);
    expect(byCashier.values.fold(0.0, (s, e) => s + e.cashSales), whole.cashSales);
    expect(byCashier.values.fold(0, (s, e) => s + e.salesCount), whole.salesCount);
    // c2 took a card and a cash sale; the tender split follows the person.
    expect(byCashier['c2']!.tenders.map((t) => t.label).toList(), ['Cash', 'Visa']);
    // The drawer belongs to the shift, so no float is attributed to anyone.
    expect(byCashier['c1']!.openingFloat, 0);
    expect(byCashier['c1']!.expectedCash, 40);
  });

  test('a shift with no sales has nobody to flash', () {
    shifts.openShift(openingFloat: 100, cashierId: 'c1');
    expect(shifts.summaryByCashier(shifts.currentOpenShift()!), isEmpty);
  });
}
