import '../../domain/order.dart';
import '../db/order_store.dart';
import 'lan_peer.dart';

/// Why a takeover did not happen, in the words the cashier is told.
///
/// A refusal is never a shrug: a tab that stays where it is has to be settled
/// there, and the waiter holding the handheld needs to know which of these it is.
enum LanClaimRefusal {
  /// The owning till did not answer. Deliberately fatal to the takeover: handing a
  /// tab over needs the owner to let go of it in the same breath, and a till that
  /// cannot be asked cannot let go. Taking it anyway is how one bill gets settled
  /// twice.
  ownerUnreachable,

  /// This device is not on the shop LAN at all, or the owning till is not a peer it
  /// has ever seen.
  noFabric,

  /// The owner answered and said no: the tab is not parked any more, it was already
  /// handed on, or that device does not allow takeovers.
  refused,
}

/// The answer to a takeover: the tab, or why not.
typedef LanClaimResult = ({Order? order, LanClaimRefusal? refusal, String? detail});

/// The one place a parked tab changes hands between two tills.
///
/// Both halves live here so the rule they share is written once: a tab moves only
/// when its current owner gives it up, and the giving up is what creates the
/// claimer's right to settle it. There is no path here that writes an order onto
/// this till without the other till having answered first.
class LanClaimDesk {
  LanClaimDesk({
    required this.deviceId,
    required OrderStore orders,
    required bool Function() allowed,
    LanLog? audit,
  })  : _orders = orders,
        _allowed = allowed,
        _audit = audit;

  /// This till's id: what it hands out as the new owner, and what it checks a
  /// granted tab against before writing it.
  final String deviceId;

  final OrderStore _orders;

  /// Whether this device lets its tabs be taken over. Read at the moment of the
  /// request rather than held, so switching it off takes effect on the next ask.
  final bool Function() _allowed;

  /// Both sides of a handover land in the audit trail, which is the point: a bill
  /// that moved between tills has to be explainable the morning after from either
  /// device on its own.
  final LanLog? _audit;

  /// The owner's half: give [orderUuid] to [toDeviceId], or say why not.
  ///
  /// Runs on the event loop between taps like every other inbound request, and
  /// touches nothing but a held order this till owns.
  LanClaimResult grant(String orderUuid, String toDeviceId, {String? cashier}) {
    if (!_allowed()) {
      _audit?.call('order.claim.refused',
          '$orderUuid to $toDeviceId: takeovers are switched off here');
      return (order: null, refusal: LanClaimRefusal.refused, detail: 'not allowed');
    }
    final moved = _orders.handOver(orderUuid, toDeviceId);
    if (moved == null) {
      // Everything that is not a parked tab of ours: already handed on, already
      // paid, on the counter, or never here at all.
      _audit?.call('order.claim.refused',
          '$orderUuid to $toDeviceId: not a parked tab on this till');
      return (order: null, refusal: LanClaimRefusal.refused, detail: 'not held here');
    }
    _audit?.call('order.claim.granted',
        '$orderUuid to $toDeviceId${cashier == null ? '' : ' for $cashier'}');
    return (order: moved, refusal: null, detail: null);
  }

  /// The claimer's half: write a tab the owning till has just let go of.
  ///
  /// The payload is checked against this device before anything is written, so a
  /// peer cannot push somebody else's bill onto this till through the same door.
  /// Saved the ordinary way, which announces it: this till now owns the tab, and
  /// that also stamps the record's clock here, so an older copy still travelling
  /// the LAN cannot arrive later and hand it back.
  Order? accept(Map<String, dynamic> payload, {String? cashier}) {
    final order = Order.fromMap(payload);
    if (order.deviceId != deviceId) return null;
    if (order.state != OrderState.held) return null;
    _orders.save(order);
    _audit?.call('order.claim.taken',
        '${order.uuid} from ${payload['claim_from'] ?? 'another till'}'
        '${cashier == null ? '' : ' by $cashier'}');
    return order;
  }
}
