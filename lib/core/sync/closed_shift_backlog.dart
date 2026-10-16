import '../../domain/order.dart';
import '../db/order_store.dart';
import '../db/shift_store.dart';

/// Paid sales still owed to Odoo from one closed shift, with the key they must be
/// booked under.
class ClosedShiftBacklog {
  const ClosedShiftBacklog({required this.batchKey, required this.orders});

  /// The idempotency key of the merged sale. A shift's own uuid, so a retry of a
  /// close that failed last night books under last night's key even after this
  /// morning's shift has opened: sent under the new shift's key, the evening's
  /// close of the new shift would reuse that key and a server that recognises
  /// repeats by key would answer `duplicate` and leave the new shift unbooked.
  final String batchKey;
  final List<Order> orders;
}

/// How many closed shifts back a retry looks for sales still owed.
const int kBacklogShiftLookback = 30;

/// The oldest closed shift that still has unsynced sales, or null when every
/// closed shift is booked.
///
/// Sales inside the open shift are never picked: they belong to its own close.
/// Sales that fall inside no shift at all (rung before this rule, or under a
/// clock that has since been fixed) are batched under a key of their own, built
/// from the oldest of them, rather than folded into a shift that has a key the
/// server may already have seen.
ClosedShiftBacklog? nextClosedShiftBacklog(ShiftStore shifts, OrderStore orders) {
  final closed = shifts.recentClosed(limit: kBacklogShiftLookback).reversed;
  final claimed = <String>{};
  for (final shift in closed) {
    final owed = orders.awaitingSyncInShift(shift);
    if (owed.isNotEmpty) return ClosedShiftBacklog(batchKey: shift.uuid, orders: owed);
  }
  final open = shifts.currentOpenShift();
  if (open != null) claimed.addAll(orders.awaitingSyncInShift(open).map((o) => o.uuid));
  final orphans = orders.awaitingSync().where((o) => !claimed.contains(o.uuid)).toList()
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  if (orphans.isEmpty) return null;
  return ClosedShiftBacklog(batchKey: 'backlog-${orphans.first.uuid}', orders: orphans);
}
