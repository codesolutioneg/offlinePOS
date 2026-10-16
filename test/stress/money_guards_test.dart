import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';

import '../db/sqlite_loader.dart';
import 'stress_till.dart';

/// Guards for the money-losing findings fixed from
/// `docs/POS_TEST_INCIDENTS_VS_OFFLINEPOS.md` (C2, C3, H3, M6). Untagged, so they
/// run with the ordinary suite and a regression fails the build.
void main() {
  late StressTill till;

  setUpAll(useSystemSqlite);
  setUp(() => till = StressTill());
  tearDown(() => till.close());

  OrderPayment cash(double amount) =>
      OrderPayment(methodId: kStressCash.id, amount: amount);

  double paidOnFloor() => [
        ...till.orders.held(),
        ...till.orders.recent(limit: 10),
      ].expand((o) => o.payments).fold<double>(0, (a, p) => a + p.amount);

  test('H3 · a second tap on Charge books no phantom sale', () {
    final s = till.session();
    till.ring(s, lines: 3);
    final due = s.current.total;
    s.pay(payments: [cash(due)], cashReceived: due);

    expect(s.pay(payments: [cash(due)], cashReceived: due), isNull);
    expect(till.orders.recent(limit: 10), hasLength(1),
        reason: 'the second pay() booked an empty order carrying real money');
  });

  test('H3 · a second tap on the same split check books nothing', () {
    final s = till.session();
    till.ring(s, lines: 3);
    final first = s.current.lines.first.uuid;
    s.payCheck([first], payments: [cash(10)]);

    expect(s.payCheck([first], payments: [cash(10)]), isNull);
    expect(till.orders.recent(limit: 10), hasLength(1));
  });

  test('C3 · moving a table keeps the share a guest already paid', () {
    final s = till.session();
    till.ring(s, lines: 4);
    s.hold(table: 'T4');
    s.recall(till.orders.held().single.uuid);
    s.payShare(payments: [cash(100)], cashReceived: 100);
    s.recall(till.orders.held().single.uuid);

    final all = s.current.lines.map((l) => l.uuid).toSet();
    final target = s.moveLinesToTable(all, 'T7');

    expect(paidOnFloor(), closeTo(100, 0.01),
        reason: 'the 100 taken at T4 vanished when the table moved to ${target.tableLabel}');
  });

  test('C3 · part of a part-paid table does not move', () {
    final s = till.session();
    till.ring(s, lines: 4);
    s.hold(table: 'T4');
    s.recall(till.orders.held().single.uuid);
    s.payShare(payments: [cash(40)], cashReceived: 40);
    s.recall(till.orders.held().single.uuid);
    final one = {s.current.lines.first.uuid};

    expect(s.canMoveLines(one), isFalse);
    s.moveLinesToTable(one, 'T7');

    expect(till.orders.held().where((o) => o.tableLabel == 'T7'), isEmpty);
    expect(s.current.lines, hasLength(4));
    expect(s.current.amountPaid, closeTo(40, 0.01));
  });

  test('C3 · merging a part-paid table keeps its payment', () {
    final s = till.session();
    till.ring(s, lines: 2);
    s.hold(table: 'T1');
    final t1 = till.orders.held().single.uuid;
    s.recall(t1);
    s.payShare(payments: [cash(50)], cashReceived: 50);
    s.newOrder();
    till.ring(s, lines: 2, seed: 5);
    s.hold(table: 'T2');
    final t2 = till.orders.held().firstWhere((o) => o.tableLabel == 'T2').uuid;

    s.recall(t2);
    s.mergeOrderInto(t1);

    expect(s.current.payments.fold<double>(0, (a, p) => a + p.amount), closeTo(50, 0.01),
        reason: 'the 50 already taken at T1 was dropped by the merge');
  });

  test('C3 · moving a whole table to an empty one keeps its kitchen number', () {
    final s = till.session();
    till.ring(s, lines: 3);
    s.hold(table: 'T3');
    final before = till.orders.held().single;
    s.recall(before.uuid);

    final all = s.current.lines.map((l) => l.uuid).toSet();
    final moved = s.moveLinesToTable(all, 'T9');

    expect(moved.uuid, before.uuid);
    expect(moved.orderNo, before.orderNo,
        reason: 'the kitchen ticket says #${before.orderNo}, the bill now says '
            '#${moved.orderNo ?? moved.displayNo}');
    expect(till.orders.held().single.tableLabel, 'T9');
  });

  test('C2 · a stale copy saved after payment does not reopen the sale', () {
    final s = till.session();
    till.ring(s, lines: 3);
    s.hold(table: 'T5');
    // What the course-fire loop holds while it waits on a slow printer.
    final stale = till.orders.held().single;

    s.recall(stale.uuid);
    till.payCash(s);
    till.orders.save(stale, announce: false);

    expect(till.orders.byUuid(stale.uuid)?.state, OrderState.paid,
        reason: 'the paid sale went back to held: gone from reports, table busy again');
  });

  test('M6 · recalling a sale that is already paid does not reopen it', () {
    final s = till.session();
    till.ring(s, lines: 2);
    final sale = till.payCash(s);

    // An Open orders list read before the payment, tapped after it.
    expect(s.recall(sale.uuid), isFalse);

    expect(till.orders.byUuid(sale.uuid)?.state, OrderState.paid,
        reason: 'a paid sale is back on the counter and can be charged again');
    expect(s.current.uuid, isNot(sale.uuid),
        reason: 'the paid sale is on screen and the next Pay books it twice');
  });
}
