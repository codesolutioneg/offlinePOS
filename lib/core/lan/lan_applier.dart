import '../../domain/order.dart';
import '../db/order_store.dart';
import '../db/reservation_store.dart';
import '../db/settings_store.dart';
import '../db/table_store.dart';
import 'lan_cart_board.dart';
import 'lan_event.dart';
import 'lan_event_log.dart';
import 'lan_shift_board.dart';
import 'lan_peer.dart';

/// What became of one event, which is what decides whether the peer's cursor may
/// move past it. A refusal is final (this till has seen it and wants no more of it);
/// a deferral is "not yet", and the cursor has to stay where the event can be found
/// again.
enum _Landing { written, refused, deferred }

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
    required SettingsStore settings,
    required ReservationStore reservations,
    required LanEventLog log,
    LanLog? onRefused,
  })  : _orders = orders,
        _tables = tables,
        _settings = settings,
        _reservations = reservations,
        _log = log,
        _onRefused = onRefused;

  /// This till's id, used to drop an event that came back to where it started.
  final String deviceId;

  final OrderStore _orders;
  final TableStore _tables;
  final SettingsStore _settings;
  final ReservationStore _reservations;
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
    int? deferredAt;
    for (final event in events) {
      if (event.seq > seen) seen = event.seq;
      switch (_land(event)) {
        case _Landing.written:
          applied++;
        case _Landing.deferred:
          deferredAt ??= event.seq;
        case _Landing.refused:
          break;
      }
    }
    var cursor = highSeq ?? seen;
    final waitingFor = deferredAt;
    if (waitingFor == null) {
      _waiting.remove(peerDeviceId);
    } else if (_mayWaitFor(peerDeviceId, waitingFor)) {
      // Hold the cursor below the first event whose order has not arrived, so the
      // next pass asks for it again. Advancing here would move past a bump that
      // nothing will ever fetch a second time, leaving a ticket permanently stale.
      // Everything before it is an upsert keyed on a uuid, so re-reading that part
      // of the page costs a write and changes nothing.
      final hold = waitingFor - 1;
      if (hold < cursor) cursor = hold;
    }
    if (cursor > 0) _log.setCursor(peerDeviceId, cursor);
    return applied;
  }

  /// How many passes a peer's cursor may wait for an order that never came, before
  /// it gives up and moves on. Without a bound, one bump for an order the owning
  /// till discarded would stop that peer's catch-up for good.
  static const int waitPasses = 10;

  /// Per peer, the seq being waited on and how many passes it has been waited on
  /// for. In memory only: a restart is welcome to try again, and re-trying is
  /// cheaper than a schema change to remember a bump we may never be able to apply.
  final Map<String, ({int seq, int passes})> _waiting = {};

  bool _mayWaitFor(String peerDeviceId, int seq) {
    final waiting = _waiting[peerDeviceId];
    if (waiting == null || waiting.seq != seq) {
      _waiting[peerDeviceId] = (seq: seq, passes: 1);
      return true;
    }
    if (waiting.passes >= waitPasses) {
      _onRefused?.call(
        'lan.event.abandoned',
        'no order arrived for $peerDeviceId seq $seq after ${waiting.passes} '
            'passes, moving the cursor past it',
      );
      _waiting.remove(peerDeviceId);
      return false;
    }
    _waiting[peerDeviceId] = (seq: seq, passes: waiting.passes + 1);
    return true;
  }

  /// Write one event. Returns false when it was skipped or refused.
  ///
  /// The record is written before its clock is stamped, deliberately. Interrupted
  /// between the two, this till re-applies the event on the next pull, and every
  /// kind here is an upsert keyed on a uuid, so a repeat lands the same row. The
  /// other order would mark a record as up to date that was never written.
  bool apply(LanEvent event) => _land(event) == _Landing.written;

  _Landing _land(LanEvent event) {
    // An event that started here has already been applied here. Belt and braces:
    // a till only ever serves its own log, so this should not arrive at all.
    if (event.originDeviceId == deviceId) return _Landing.refused;
    try {
      if (!_wins(event)) return _Landing.refused;
      if ((event.kind == LanEventKind.kitchenStatus ||
              event.kind == LanEventKind.orderClaim) &&
          _orders.byUuid(event.recordUuid) == null) {
        // Deferred rather than refused: the owning till's upsert is still coming,
        // and the difference decides whether the cursor may move past this.
        return _Landing.deferred;
      }
      final written = switch (event.kind) {
        LanEventKind.orderUpsert => _applyOrder(event),
        LanEventKind.kitchenStatus => _applyKitchenStatus(event),
        LanEventKind.tableUpsert => _applyTable(event),
        LanEventKind.productAvailability => _applyAvailability(event),
        LanEventKind.orderClaim => _applyClaim(event),
        LanEventKind.reservationUpsert => _applyReservation(event),
        LanEventKind.shiftLifecycle => _applyShiftNotice(event),
        LanEventKind.cartDisplay => _applyCart(event),
      };
      if (!written) return _Landing.refused;
      _log.stampClock(event.recordUuid, event.kind, event.at, event.originDeviceId);
      return _Landing.written;
    } catch (e) {
      // A malformed or unreadable event is dropped, never retried into a crash
      // loop and never allowed near the till's own state.
      _onRefused?.call('lan.event.refused',
          '${event.kind.wire} ${event.recordUuid} from ${event.originDeviceId}: $e');
      return _Landing.refused;
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
    // Belt and braces: [_land] already deferred this case, holding the cursor so the
    // bump is fetched again once the order arrives. Inventing an order here instead
    // would put a ticket on the board that no till owns.
    if (_orders.byUuid(event.recordUuid) == null) return false;
    _orders.setKitchenStatus(event.recordUuid, status, announce: false);
    return true;
  }

  /// A tab that changed hands somewhere else. Every till follows the owner, so the
  /// floor plan on a third device knows which till to send a waiter to.
  bool _applyClaim(LanEvent event) {
    final to = event.payload['to'];
    if (to is! String) throw FormatException('claim for ${event.recordUuid}');
    return _orders.applyHandOver(event.recordUuid, to);
  }

  bool _applyAvailability(LanEvent event) {
    final id = event.payload['product_id'];
    if (id is! int) throw FormatException('availability for ${event.recordUuid}');
    _settings.applyProductAvailable(id, event.payload['available'] == true);
    return true;
  }

  /// What another till has on its counter, for a display to show. Kept on a board
  /// and nothing else: a cart is not an order and must never become one here.
  bool _applyCart(LanEvent event) {
    LanCartBoard(_settings).remember(LanCartSnapshot.fromMap(event.payload));
    return true;
  }

  /// A till telling the shop its day is over. Written to the board the floor reads,
  /// never acted on here: what a device does about it is a policy the device owns,
  /// and applying an event must not be able to stop anybody selling.
  bool _applyShiftNotice(LanEvent event) {
    LanShiftBoard(_settings).remember(LanShiftNotice.fromMap(event.payload));
    return true;
  }

  bool _applyReservation(LanEvent event) {
    if (event.payload['deleted'] == true) {
      _reservations.remove(event.recordUuid, announce: false);
      return true;
    }
    _reservations.save(Reservation.fromMap(event.payload), announce: false);
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
