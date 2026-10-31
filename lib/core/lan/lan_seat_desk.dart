import '../db/order_store.dart';

/// What the shop's primary till said about seating a table.
enum LanSeatAnswer {
  /// Nobody else holds the table: seat it.
  granted,

  /// Another till has a tab there, or reserved it a moment ago.
  busy,

  /// The primary could not be asked. The till seats anyway, because a shop whose
  /// switch died must still sell; the floor settles it on the next pull.
  unasked,
}

/// The primary till's short-lived record of who is seating which table.
///
/// Replication between tills runs every few seconds, so two waiters tapping the
/// same empty table inside that window each saw it free. Asking one till first
/// closes that window: the primary answers from its own replica of every tab plus
/// the seats it granted in the last [holdFor], which covers the gap until the new
/// tab has replicated to it.
class LanSeatDesk {
  LanSeatDesk({
    required OrderStore orders,
    this.holdFor = const Duration(seconds: 30),
    DateTime Function()? now,
  })  : _orders = orders,
        _now = now ?? DateTime.now;

  final OrderStore _orders;
  final DateTime Function() _now;

  /// How long a granted seat blocks other tills before replication takes over.
  final Duration holdFor;

  final Map<String, ({String deviceId, DateTime at})> _holds = {};

  /// Reserve [table] for [deviceId], or say it is taken.
  LanSeatAnswer reserve(String table, String deviceId) {
    final label = table.trim();
    if (label.isEmpty) return LanSeatAnswer.granted;
    for (final o in _orders.occupyingAnywhere()) {
      if (o.tableLabel == label && o.deviceId != deviceId) return LanSeatAnswer.busy;
    }
    final now = _now();
    _holds.removeWhere((_, h) => now.difference(h.at) > holdFor);
    final held = _holds[label];
    if (held != null && held.deviceId != deviceId) return LanSeatAnswer.busy;
    _holds[label] = (deviceId: deviceId, at: now);
    return LanSeatAnswer.granted;
  }
}
