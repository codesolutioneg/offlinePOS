import '../../../core/printing/kitchen_ticket.dart';
import '../../../domain/order.dart';
import 'stress_cashier.dart';
import 'stress_timed.dart';
import 'stress_trace.dart';

/// A takeaway or to-go: ring, kitchen, pay, receipt.
Future<void> takeawayScenario(StressCashier c, OrderTrace t) async {
  final type = c.nextInt(2) == 0 ? OrderType.takeaway : OrderType.toGo;
  await c.step(
    t,
    'new order',
    () => c.session.startFresh(type),
    where: type.name,
  );
  await c.ring(t, 2 + c.nextInt(4));
  await c.kitchen(t, c.session.current);
  await c.pause();
  await c.payAll(t);
}

/// A table that orders, is parked, comes back for a second round and pays.
Future<void> holdRecallScenario(StressCashier c, OrderTrace t) async {
  final table = await c.takeTable(t);
  try {
    await c.seat(t, table);
    await c.ring(t, 3);
    await c.kitchen(t, c.session.current);
    final uuid = await c.hold(t, table: table);
    await c.pause();
    await c.recall(t, uuid);
    await c.ring(t, 2);
    await c.kitchen(t, c.session.current);
    await c.pause();
    await c.payAll(t);
  } finally {
    c.tables.release(table);
  }
}

/// Starters now, mains on a course timer: the table is parked and the till's own
/// tick has to fire the mains when they come due.
Future<void> timedSendScenario(StressCashier c, OrderTrace t) async {
  final table = await c.takeTable(t);
  try {
    await c.seat(t, table);
    await c.ring(t, 2);
    await c.kitchen(t, c.session.current);
    await c.ring(t, 2);
    final due = DateTime.now().toUtc().add(kStressTimedDelay);
    await c.step(t, 'course timer', () {
      for (final l in c.session.current.lines) {
        if (!l.printedToKitchen) l.fireAt = due;
      }
      c.deps.orders.save(c.session.current);
    }, where: '+${kStressTimedDelay.inSeconds} s');
    t.timedDue = due;
    final uuid = await c.hold(t, table: table);
    await awaitTimedFire(c, t, uuid, c.ticker);
    await c.recall(t, uuid);
    await c.payAll(t);
  } finally {
    c.tables.release(table);
  }
}

/// Half a table moves to another table, then what is left moves to a third, and
/// both bills pay.
Future<void> transferScenario(StressCashier c, OrderTrace t) async {
  final from = await c.takeTable(t);
  final to = await c.takeTable(t);
  final last = await c.takeTable(t);
  try {
    await c.seat(t, from);
    await c.ring(t, 4);
    await c.kitchen(t, c.session.current);
    await c.pause();
    final source = c.session.current;
    final moving = source.lines.take(2).map((l) => l.uuid).toSet();
    final target = await c.step(t, 'move items', () {
      final moved = c.session.moveLinesToTable(moving, to);
      if (moved.uuid == source.uuid) throw StateError('move to $to refused');
      return moved;
    }, where: to);
    t.splitInto.add(target.uuid);
    await c.step(t, 'move table', () {
      c.session.splitTabToTable(last);
      if (c.session.current.tableLabel != last) {
        throw StateError('move to $last refused');
      }
    }, where: last);
    t.table = last;
    await c.payAll(t);
    await c.pause();
    await c.recall(t, target.uuid);
    await c.payAll(t);
  } finally {
    c.tables
      ..release(from)
      ..release(to)
      ..release(last);
  }
}

/// Two tables join: the first is parked, the second folds it in and pays for both.
Future<void> mergeScenario(StressCashier c, OrderTrace t) async {
  final first = await c.takeTable(t);
  final second = await c.takeTable(t);
  try {
    await c.seat(t, first);
    await c.ring(t, 2);
    await c.kitchen(t, c.session.current);
    final away = await c.hold(t, table: first);
    final awayTotal = c.deps.orders.byUuid(away)?.total ?? 0;
    await c.seat(t, second);
    await c.ring(t, 3);
    await c.kitchen(t, c.session.current);
    final before = c.session.current.total;
    await c.step(
      t,
      'merge tables',
      () => c.session.mergeOrderInto(away),
      where: first,
    );
    t.expectGone(away);
    final after = c.session.current.total;
    if ((after - before - awayTotal).abs() > 0.01) {
      t.add(
        'merge total',
        failed: true,
        detail:
            '${awayTotal.toStringAsFixed(2)} + ${before.toStringAsFixed(2)} '
            'became ${after.toStringAsFixed(2)}',
      );
    }
    await c.payAll(t);
  } finally {
    c.tables
      ..release(first)
      ..release(second);
  }
}

/// An item the kitchen already has is voided, so a cancel slip goes to the pass.
Future<void> voidScenario(StressCashier c, OrderTrace t) async {
  await c.step(t, 'new order', () => c.session.startFresh(OrderType.takeaway));
  await c.ring(t, 4);
  await c.kitchen(t, c.session.current);
  final line = c.session.current.lines.first;
  final voided = await c.step(t, 'void item', () {
    final v = c.session.voidLine(line.uuid, 'stress void');
    if (v == null) throw StateError('void refused');
    return v;
  }, where: line.name);
  final cancel = c.deps.voidToKitchen;
  if (cancel != null && voided.printedToKitchen) {
    final snapshot = Order.fromMap(c.session.current.toMap());
    final r = await c.step(
      t,
      'kitchen cancel',
      () => cancel(snapshot, voided, 'stress void'),
      where: 'kitchen',
    );
    t.add(
      'kitchen cancel answer',
      detail: r.name,
      failed: r == KitchenFireResult.lost,
    );
  }
  await c.payAll(t);
}
