import '../../domain/order.dart';
import '../db/order_store.dart';
import '../db/table_store.dart';
import 'lan_event.dart';
import 'lan_event_log.dart';
import 'lan_peer.dart';

/// Writes what a peer sent into this till's own database, through the same stores
/// every screen already reads.
///
/// This class holds no outbox and no sender, and that is the point rather than an
/// omission: only the till that took the money books the sale, so the replicated
/// path must have no way to reach an enqueue. There is nothing to review for
/// "does it accidentally push someone else's order" because there is nothing here
/// that could.
///
/// Nothing here runs on a selling path. Every method is called from the fabric's
/// own timer or from an inbound request, so a malformed event costs a log line.
class LanApplier {
  LanApplier({
    required this.deviceId,
    required OrderStore orders,
    required TableStore tables,
    required LanEventLog log,
    LanLog? onRefused,
  })  : _orders = orders,
        _tables = tables,
        _log = log,
        _onRefused = onRefused;

  /// This till's id, used to drop an event that came back to where it started.
  final String deviceId;

  final OrderStore _orders;
  final TableStore _tables;
  final LanEventLog _log;
  final LanLog? _onRefused;

  /// Apply a page of events from one peer and advance that peer's cursor to
  /// [highSeq] (the highest seq the peer served, which is not always the highest
  /// one applied: an event refused by the conflict rule has still been seen, and
  /// leaving the cursor behind it would fetch it again forever).
  ///
  /// Returns how many were actually written. Never throws.
  int applyAll(String peerDeviceId, List<LanEvent> events, {int? highSeq}) {
    var applied = 0;
    var seen = 0;
    for (final event in events) {
      if (event.seq > seen) seen = event.seq;
      if (apply(event)) applied++;
    }
    final cursor = highSeq ?? seen;
    if (cursor > 0) _log.setCursor(peerDeviceId, cursor);
    return applied;
  }

  /// Write one event. Returns false when it was skipped or refused.
  ///
  /// The record is written before its clock is stamped, deliberately. Interrupted
  /// between the two, this till re-applies the event on the next pull, and every
  /// kind here is an upsert keyed on a uuid, so a repeat lands the same row. The
  /// other order would mark a record as up to date that was never written.
  bool apply(LanEvent event) {
    // An event that started here has already been applied here. Belt and braces:
    // a till only ever serves its own log, so this should not arrive at all.
    if (event.originDeviceId == deviceId) return false;
    try {
      if (!_wins(event)) return false;
      final written = switch (event.kind) {
        LanEventKind.orderUpsert => _applyOrder(event),
        LanEventKind.kitchenStatus => _applyKitchenStatus(event),
        LanEventKind.tableUpsert => _applyTable(event),
      };
      if (!written) return false;
      _log.stampClock(event.recordUuid, event.kind, event.at, event.originDeviceId);
      return true;
    } catch (e) {
      // A malformed or unreadable event is dropped, never retried into a crash
      // loop and never allowed near the till's own state.
      _onRefused?.call('lan.event.refused',
          '${event.kind.wire} ${event.recordUuid} from ${event.originDeviceId}: $e');
      return false;
    }
  }

  /// The conflict rule, in one place: last write wins per record, and when two
  /// tills stamp the very same instant the higher device id wins.
  ///
  /// The tiebreak is arbitrary but it is the same arbitrary answer on every device,
  /// which is the property that matters: two tills that disagree about who wrote
  /// last must not each keep their own version forever.
  bool _wins(LanEvent event) {
    final clock = _log.clockFor(event.recordUuid);
    if (clock == null) return true;
    if (event.at.isAfter(clock.at)) return true;
    if (event.at.isBefore(clock.at)) return false;
    return event.originDeviceId.compareTo(clock.origin) > 0;
  }

  bool _applyOrder(LanEvent event) {
    if (event.payload['deleted'] == true) {
      // A tab the owning till discarded. delete() only removes an unpaid order, so
      // this can never quietly erase a sale.
      _orders.delete(event.recordUuid, announce: false);
      return true;
    }
    final incoming = Order.fromMap(event.payload);
    // State only moves forward. A paid order never loses to a held one, whatever
    // the clocks say: money taken is not something a later edit can undo, and the
    // till that took it is the one that books it.
    final local = _orders.byUuid(incoming.uuid);
    if (local != null && _rank(incoming.state) < _rank(local.state)) return false;
    // announce: false, so applying a peer's order does not make this till claim
    // authorship of it and send it back.
    _orders.save(incoming, announce: false);
    return true;
  }

  bool _applyKitchenStatus(LanEvent event) {
    final status = KitchenStatus.values.byName('${event.payload['status']}');
    // Nothing to advance means the order has not reached this till yet. Refusing
    // (rather than inventing an order) is safe: the owning till's own upsert is
    // still coming, and the bump will be pulled again on the next pass.
    if (_orders.byUuid(event.recordUuid) == null) return false;
    _orders.setKitchenStatus(event.recordUuid, status, announce: false);
    return true;
  }

  bool _applyTable(LanEvent event) {
    if (event.payload['deleted'] == true) {
      _tables.remove(event.recordUuid, announce: false);
      return true;
    }
    _tables.upsert(PosTable.fromMap(event.payload), announce: false);
    return true;
  }

  /// How far along an order is. Only ever compared, never stored.
  static int _rank(OrderState state) => switch (state) {
        OrderState.draft => 0,
        OrderState.held => 1,
        OrderState.paid => 2,
        OrderState.synced => 3,
      };
}
