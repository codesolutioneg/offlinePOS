import '../../../domain/order.dart';
import 'stress_cashier.dart';
import 'stress_trace.dart';

/// How far ahead a lab course timer is set.
const Duration kStressTimedDelay = Duration(seconds: 5);

/// A timed line fired later than this after it was due counts as late.
const Duration kStressTimedLate = Duration(seconds: 15);

/// The till's course-timer tick, shared by every virtual cashier on the till.
///
/// One tick fires every due line on the floor, whoever rang it, so the cashiers
/// share it rather than each ticking on its own: two ticks a moment apart would
/// both see a line the first is still printing and fire it twice, which is the
/// run tripping over itself, not the till. The till's own tick is every 30 s.
class StressTimedTicker {
  StressTimedTicker({this.every = const Duration(seconds: 10)});

  final Duration every;
  DateTime? _last;

  /// Run [tick] unless one ran within [every].
  void maybeTick(void Function() tick) {
    final now = DateTime.now();
    final last = _last;
    if (last != null && now.difference(last) < every) return;
    _last = now;
    tick();
  }
}

/// Wait for the course timer on [orderUuid] to come due, let the till's tick fire
/// it, and record how late the kitchen got it. Without a till tick (printing off,
/// tests) the due lines are fired here, as the tick would.
Future<void> awaitTimedFire(
  StressCashier c,
  OrderTrace t,
  String orderUuid,
  StressTimedTicker ticker,
) async {
  final due = t.timedDue;
  if (due == null) return;
  final wait = due.difference(DateTime.now().toUtc());
  if (wait > Duration.zero) await Future<void>.delayed(wait);
  final sw = Stopwatch()..start();
  const limit = Duration(seconds: 60);
  while (sw.elapsed < limit) {
    final o = c.deps.orders.byUuid(orderUuid);
    if (o == null) break;
    if (o.lines.every((l) => l.printedToKitchen)) {
      t.timedFired = DateTime.now().toUtc();
      final late = t.timedFired!.difference(due);
      t.add(
        'timed fire',
        detail: 'late by ${(late.inMilliseconds / 1000).toStringAsFixed(1)} s',
        micros: sw.elapsedMicroseconds,
        where: 'kitchen',
      );
      return;
    }
    final tick = c.deps.fireDueTimed;
    if (tick != null) {
      ticker.maybeTick(tick);
    } else {
      _fireDue(c, o);
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  t.add(
    'timed fire',
    detail: 'never fired',
    micros: sw.elapsedMicroseconds,
    failed: true,
  );
}

void _fireDue(StressCashier c, Order o) {
  final now = DateTime.now().toUtc();
  final due = o.lines.where(
    (l) => l.fireAt != null && !l.printedToKitchen && l.dueAt(now),
  );
  if (due.isNotEmpty) c.markFired(o, only: due.toList());
}
