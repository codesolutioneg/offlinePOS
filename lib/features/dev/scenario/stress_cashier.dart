import 'dart:async';
import 'dart:math';

import '../../../app/pos_session.dart';
import '../../../core/printing/kitchen_ticket.dart';
import '../../../domain/catalogue.dart';
import '../../../domain/order.dart';
import 'stress_deps.dart';
import 'stress_table_pool.dart';
import 'stress_timed.dart';
import 'stress_trace.dart';

/// One virtual cashier: its own [PosSession] on the till's database, the menu and
/// tender the run picked, and the steps every scenario is written in.
///
/// Every step is timed and written to the order's trace, and a step that throws
/// is written as failed before the error stops the scenario.
class StressCashier {
  StressCashier({
    required this.id,
    required this.deps,
    required this.session,
    required this.menu,
    required this.tender,
    required this.tables,
    required this.ticker,
    required int seed,
    this.pace = const Duration(milliseconds: 40),
  }) : _rand = Random(seed);

  final String id;
  final StressDeps deps;
  final PosSession session;
  final List<Product> menu;
  final PaymentMethod tender;
  final StressTablePool tables;
  final StressTimedTicker ticker;

  /// How long a cashier "thinks" between steps, jittered, so several cashiers'
  /// steps interleave the way a busy floor's do.
  final Duration pace;
  final Random _rand;

  int nextInt(int max) => _rand.nextInt(max);

  Future<void> pause() =>
      Future<void>.delayed(pace * (0.5 + _rand.nextDouble()));

  /// Run [body] as one step of [t]: timed, recorded, and recorded as failed if it
  /// throws (the error still propagates, so the scenario stops there).
  Future<T> step<T>(
    OrderTrace t,
    String name,
    FutureOr<T> Function() body, {
    String? where,
  }) async {
    final sw = Stopwatch()..start();
    try {
      final out = await body();
      t.add(name, micros: sw.elapsedMicroseconds, where: where);
      return out;
    } catch (e) {
      t.add(
        name,
        detail: '$e',
        micros: sw.elapsedMicroseconds,
        failed: true,
        where: where,
      );
      rethrow;
    }
  }

  /// Put [lines] different items on the bill on the counter, so each is its own
  /// line for the split and move steps to pick from.
  Future<void> ring(OrderTrace t, int lines) => step(t, 'ring', () {
    final start = nextInt(menu.length);
    for (var i = 0; i < lines; i++) {
      session.addProduct(
        menu[(start + i) % menu.length],
        qty: 1 + nextInt(2).toDouble(),
      );
    }
    t.bind(session.current);
  }, where: '$lines items');

  /// Open a fresh dine-in bill seated at [table].
  Future<void> seat(OrderTrace t, String table) => step(t, 'seat', () {
    session.startFresh(OrderType.dineIn);
    session.claimSeat(table);
    t.bind(session.current);
  }, where: table);

  /// Send what is due on [order] to the kitchen, the way the Send button does,
  /// and wait for it: the till writes the fired lines back once the paper is out.
  Future<void> kitchen(OrderTrace t, Order order) async {
    final fire = deps.fireKitchen;
    if (fire == null) {
      t.kitchenSimulated = true;
      await step(t, 'kitchen (simulated)', () => markFired(order));
      return;
    }
    final result = await step(
      t,
      'kitchen',
      () => fire(order),
      where: 'kitchen',
    );
    t.add(
      'kitchen answer',
      detail: result.name,
      failed: result == KitchenFireResult.lost,
    );
    t.bind(order);
  }

  /// What a kitchen that printed would leave behind: every due line fired.
  void markFired(Order order, {List<OrderLine>? only}) {
    final now = DateTime.now().toUtc();
    for (final l in only ?? order.lines.where((l) => l.dueAt(now))) {
      l.printedToKitchen = true;
    }
    deps.orders.save(order);
  }

  /// Pay the bill on the counter in full and print its receipt.
  Future<Order> payAll(OrderTrace t) async {
    final due = session.current.total;
    final sale = await step(t, 'pay', () {
      final s = session.pay(
        payments: [OrderPayment(methodId: tender.id, amount: due)],
        cashReceived: due,
      );
      if (s == null) throw StateError('nothing on the counter to pay');
      return s;
    }, where: due.toStringAsFixed(2));
    t.bind(sale);
    t.expect(sale);
    await receipt(t, sale);
    return sale;
  }

  Future<void> receipt(OrderTrace t, Order sale) async {
    final print = deps.printReceipt;
    if (print == null) return;
    await step(t, 'receipt', () => print(sale), where: 'receipt printer');
  }

  /// Bring a parked order back to the counter.
  Future<void> recall(OrderTrace t, String orderUuid) => step(t, 'recall', () {
    if (!session.recall(orderUuid)) {
      throw StateError('recall refused for $orderUuid');
    }
  });

  /// Park the bill on the counter (on [table] when given) and hand back its uuid.
  Future<String> hold(OrderTrace t, {String? table}) => step(t, 'hold', () {
    final o = session.current;
    session.hold(table: table);
    t.bind(o);
    t.expect(o);
    return o.uuid;
  }, where: table);

  /// How many tables one take tries before calling the floor full.
  static const int seatAttempts = 5;

  /// A free table the primary agreed to, or a failed step when the floor is full.
  /// A table another till has just taken is passed over, as a cashier would.
  Future<String> takeTable(OrderTrace t) => step(t, 'take table', () async {
    final refused = <String>[];
    try {
      for (var i = 0; i < seatAttempts; i++) {
        final table = tables.take();
        if (table == null) break;
        final reserve = deps.reserveSeat;
        if (reserve == null || await reserve(table)) return table;
        refused.add(table);
      }
      throw StateError(refused.isEmpty
          ? 'no free table'
          : 'no free table (taken on another till: ${refused.join(', ')})');
    } finally {
      refused.forEach(tables.release);
    }
  });
}
