import '../../domain/order.dart';
import '../db/order_store.dart';
import '../db/shift_store.dart';
import '../db/sqlite_outbox_store.dart';
import 'outbox.dart';
import 'sync_service.dart';

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
/// Sales held here from every till count, the same set a session close sends:
/// only the closing till sends sales, so a sale another till handed over is
/// owed by this one. Batches whose key is in [skip] are passed over.
///
/// Sales inside the open shift are never picked: they belong to its own close.
/// Nor are sales rung after the last close, such as another till still selling
/// once this one closed: the next close takes them. Sales older than the last
/// close that fall inside no shift (rung before this rule, or under a clock that
/// has since been fixed) are batched under a key of their own, built from the
/// oldest of them, rather than folded into a shift that has a key the server may
/// already have seen.
///
/// Sales [held] names (parked in the queue, such as those held when the server
/// changed) are left out: they wait for a manager, and stay owed meanwhile.
/// A batch with any sale [sessionHeld] names is not sent at all: the server
/// rejected it whole, and it goes again whole once a manager revives it.
ClosedShiftBacklog? nextClosedShiftBacklog(ShiftStore shifts, OrderStore orders,
    {Set<String> skip = const {},
    Set<String> Function(Iterable<String>)? held,
    Set<String> Function(Iterable<String>)? sessionHeld}) {
  bool parkedWhole(List<Order> owed) =>
      sessionHeld != null && sessionHeld(owed.map((o) => o.uuid)).isNotEmpty;
  List<Order> sendable(List<Order> owed) {
    if (held == null || owed.isEmpty) return owed;
    final parked = held(owed.map((o) => o.uuid));
    return owed.where((o) => !parked.contains(o.uuid)).toList();
  }

  final closed = shifts.recentClosed(limit: kBacklogShiftLookback).reversed;
  final claimed = <String>{};
  DateTime? lastClose;
  for (final shift in closed) {
    final at = shift.closedAt;
    if (at != null && (lastClose == null || at.isAfter(lastClose))) lastClose = at;
    final owed = orders.awaitingSyncInShift(shift, anyDevice: true);
    claimed.addAll(owed.map((o) => o.uuid));
    if (parkedWhole(owed)) continue;
    final send = sendable(owed);
    if (send.isNotEmpty && !skip.contains(shift.uuid)) {
      return ClosedShiftBacklog(batchKey: shift.uuid, orders: send);
    }
  }
  final open = shifts.currentOpenShift();
  if (open != null) {
    claimed.addAll(
        orders.awaitingSyncInShift(open, anyDevice: true).map((o) => o.uuid));
  }
  if (lastClose == null) return null;
  final strays = orders
      .awaitingSync(anyDevice: true)
      .where((o) => !claimed.contains(o.uuid) && o.createdAt.isBefore(lastClose!))
      .toList();
  if (parkedWhole(strays)) return null;
  final orphans = sendable(strays)
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  if (orphans.isEmpty) return null;
  final key = 'backlog-${orphans.first.uuid}';
  if (skip.contains(key)) return null;
  return ClosedShiftBacklog(batchKey: key, orders: orphans);
}

/// Send every batch [nextClosedShiftBacklog] finds, oldest first.
///
/// Stops at the first batch that could not be sent, since the next one would
/// fail the same way. A batch the server refused is different: it needs a
/// person, and the batches behind it are passed to [flush] all the same. The
/// refused one stays owed and its result is what is returned. One the server
/// itself rejected is parked whole, so it is not sent again on every retry
/// until a manager sends it again as one batch.
///
/// What a booked batch carried is told to the whole shop: some of its sales may
/// be another till's, and that till would otherwise send them again at its own
/// close. Only sales the booking marked synced are told.
///
/// Sales parked in [outbox] are left out: sent here they could carry another
/// server's product ids, and left in the batch they would be marked synced.
Future<ShiftFlushResult> sendClosedShiftBacklog(
  ShiftStore shifts,
  OrderStore orders,
  Future<ShiftFlushResult> Function(ClosedShiftBacklog backlog) flush, {
  required SqliteOutboxStore outbox,
}) async {
  Set<String> held(Iterable<String> uuids) =>
      outbox.statesOf(SqliteOutboxStore.orderPush, uuids).refused;
  ShiftFlushResult result = const ShiftFlushResult(merged: true, orderCount: 0);
  ShiftFlushResult? refused;
  final tried = <String>{};
  for (var i = 0; i < kBacklogShiftLookback; i++) {
    final backlog = nextClosedShiftBacklog(shifts, orders,
        skip: tried, held: held, sessionHeld: outbox.sessionHeldOf);
    if (backlog == null) break;
    tried.add(backlog.batchKey);
    result = await flush(backlog);
    if (result.merged) {
      orders.tellShopBooked(backlog.orders.map((o) => o.uuid));
      continue;
    }
    if (!result.refused) return result;
    if (result.rejected) {
      outbox.holdSession(backlog.batchKey, backlog.orders.map((o) => o.uuid),
          result.skipReason ?? 'batch refused by the server');
    }
    refused ??= result;
  }
  return refused ?? result;
}

/// Book [sales] as one sale order under [batchKey], as a session close and its
/// resend do: each is queued again (a refused row from a partial push is
/// revived), and only the sales the booking marked synced are told to the shop.
/// A batch the server rejected is parked whole, as [sendClosedShiftBacklog]
/// parks one, so no retry sends it until a manager does. A batch already parked
/// is refused here: only the manager's resend on Diagnostics revives it.
Future<ShiftFlushResult> bookSessionSales(
  SyncService sync,
  Outbox outbox,
  SqliteOutboxStore store,
  OrderStore orders,
  List<Order> sales,
  String batchKey,
) async {
  if (store.sessionHeldOf(sales.map((o) => o.uuid)).isNotEmpty) {
    return ShiftFlushResult(
      merged: false,
      orderCount: sales.length,
      skipReason: 'the server rejected it before',
      refused: true,
      held: true,
    );
  }
  final result = await sync.flushClosedShift(
    orderUuids: {for (final o in sales) o.uuid},
    batchKey: batchKey,
    enqueueOrders: () async {
      for (final o in sales) {
        await outbox.enqueue(
            SqliteOutboxStore.orderPush, o.uuid, o.toServerPayload());
        store.reviveByKey(SqliteOutboxStore.orderPush, o.uuid);
      }
    },
  );
  if (result.merged) orders.tellShopBooked(sales.map((o) => o.uuid));
  if (result.rejected) {
    store.holdSession(batchKey, sales.map((o) => o.uuid),
        result.skipReason ?? 'batch refused by the server');
  }
  return result;
}
