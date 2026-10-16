import '../../../domain/order.dart';
import 'stress_cashier.dart';
import 'stress_trace.dart';

/// A table splits its items over two checks, one item shared half and half, and
/// each check pays on its own.
Future<void> splitItemsScenario(StressCashier c, OrderTrace t) async {
  final table = await c.takeTable(t);
  try {
    await c.seat(t, table);
    await c.ring(t, 4);
    await c.kitchen(t, c.session.current);
    final order = c.session.current;
    final l = order.lines;
    if (l.length < 4) throw StateError('only ${l.length} lines to split');
    t.splitFrom = order.total;
    final checks = await c.step(t, 'split by items', () {
      final made = c.session.splitIntoChecks([
        [
          (line: l[0].uuid, quantity: l[0].quantity / 2),
          (line: l[1].uuid, quantity: l[1].quantity),
        ],
        [
          (line: l[0].uuid, quantity: l[0].quantity / 2),
          (line: l[2].uuid, quantity: l[2].quantity),
          (line: l[3].uuid, quantity: l[3].quantity),
        ],
      ]);
      if (made.length < 2) throw StateError('split made ${made.length} check');
      return made;
    }, where: '2 checks');
    for (final check in checks.skip(1)) {
      t.splitInto.add(check.uuid);
    }
    for (var i = 0; i < checks.length; i++) {
      if (i > 0) await c.recall(t, checks[i].uuid);
      await c.payAll(t);
      await c.pause();
    }
  } finally {
    c.tables.release(table);
  }
}

/// One guest pays their own items as a separate check; the table pays the rest.
Future<void> splitCheckScenario(StressCashier c, OrderTrace t) async {
  final table = await c.takeTable(t);
  try {
    await c.seat(t, table);
    await c.ring(t, 4);
    await c.kitchen(t, c.session.current);
    t.splitFrom = c.session.current.total;
    final mine = c.session.current.lines.take(2).map((l) => l.uuid).toList();
    final due = c.session.checkTotal(c.session.current.lines.take(2));
    final check = await c.step(t, 'pay own items', () {
      final paid = c.session.payCheck(
        mine,
        payments: [OrderPayment(methodId: c.tender.id, amount: due)],
        cashReceived: due,
      );
      if (paid == null) throw StateError('check refused');
      return paid;
    }, where: due.toStringAsFixed(2));
    t.splitInto.add(check.uuid);
    t.expect(check);
    await c.receipt(t, check);
    await c.pause();
    await c.payAll(t);
  } finally {
    c.tables.release(table);
  }
}

/// The bill is shared evenly between two to four guests, each paying a share.
Future<void> splitPersonsScenario(StressCashier c, OrderTrace t) async {
  final table = await c.takeTable(t);
  try {
    await c.seat(t, table);
    await c.ring(t, 3);
    await c.kitchen(t, c.session.current);
    final order = c.session.current;
    final guests = 2 + c.nextInt(3);
    final total = order.total;
    t.splitFrom = total;
    final share = (total / guests * 100).floorToDouble() / 100;
    double? left;
    for (var i = 1; i <= guests; i++) {
      final amount = i == guests ? order.balance : share;
      left = await c.step(t, 'share $i/$guests', () {
        final rest = c.session.payShare(
          payments: [OrderPayment(methodId: c.tender.id, amount: amount)],
          cashReceived: amount,
        );
        if (rest == null) throw StateError('share refused');
        return rest;
      }, where: amount.toStringAsFixed(2));
      await c.pause();
    }
    if (left != 0) t.add('shares settle', failed: true, detail: 'left $left');
    t.expect(order);
    await c.receipt(t, order);
  } finally {
    c.tables.release(table);
  }
}
