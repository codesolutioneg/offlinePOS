import '../sync/device_status.dart';

/// The hours the shop is trading, in local time.
///
/// Restaurants close after midnight, so the window wraps: opening at 08:00 and
/// closing at 04:00 leaves 04:00-08:00 as the only time a restart costs nothing.
/// The default close matches the business-day cutover, so an install can only
/// happen once the previous trading day is finished and cashed up.
class ServiceHours {
  const ServiceHours({this.opensAtHour = 8, this.closesAtHour = 4});

  final int opensAtHour;
  final int closesAtHour;

  bool contains(DateTime localTime) {
    final hour = localTime.hour;
    if (opensAtHour == closesAtHour) return true;
    if (opensAtHour < closesAtHour) {
      return hour >= opensAtHour && hour < closesAtHour;
    }
    return hour >= opensAtHour || hour < closesAtHour;
  }
}

/// Everything the gate needs to know about this till, right now.
class TillState {
  const TillState({
    required this.localTime,
    this.pendingSales = 0,
    this.rejectedSales = 0,
    this.saleInProgress = false,
    this.soleTill = true,
  });

  /// Local wall clock, not UTC: service hours are a property of the shop.
  final DateTime localTime;

  /// Sales still waiting for the server. `SqliteOutboxStore.pendingCount`.
  final int pendingSales;

  /// Sales the server refused. `SqliteOutboxStore.deadCount`.
  final int rejectedSales;

  /// A cashier has lines on screen or a payment open.
  final bool saleInProgress;

  /// No other till in the shop can take money while this one restarts. Defaults to
  /// true because assuming a second till exists is how a single-till shop ends up
  /// with no way to sell.
  final bool soleTill;

  /// Built from the same numbers the heartbeat reports, so the gate and support are
  /// never looking at two different counts.
  factory TillState.fromDeviceStatus(
    DeviceStatus status, {
    required DateTime localTime,
    bool saleInProgress = false,
    bool soleTill = true,
  }) =>
      TillState(
        localTime: localTime,
        pendingSales: status.pending,
        rejectedSales: status.dead,
        saleInProgress: saleInProgress,
        soleTill: soleTill,
      );
}

enum UpdateBlocker {
  /// Money on this device that exists nowhere else.
  unsyncedSales,

  /// Sales the server refused. Someone has to look at them first.
  rejectedSales,

  /// A customer is standing there mid-order.
  saleInProgress,

  /// The shop is trading.
  serviceHours,

  /// Mandatory would have overridden the clock, but there is no second till to sell
  /// on while this one restarts.
  soleTillInService,
}

/// One reason the till is not being updated, in words a manager can act on.
class UpdateHold {
  const UpdateHold(this.blocker, this.reason);

  final UpdateBlocker blocker;
  final String reason;

  @override
  String toString() => reason;
}

/// The gate's answer. Deliberately not a bool: every wait has to be explainable,
/// or the shop concludes the update is broken and someone installs it by hand at
/// the worst possible moment.
class UpdateDecision {
  const UpdateDecision(this.holds);

  const UpdateDecision.allow() : holds = const [];

  /// Most serious first.
  final List<UpdateHold> holds;

  bool get allowed => holds.isEmpty;

  UpdateHold? get primary => holds.isEmpty ? null : holds.first;

  Set<UpdateBlocker> get blockers => {for (final h in holds) h.blocker};

  /// Nobody at the shop can clear this one; it needs support.
  bool get needsSupport => blockers.contains(UpdateBlocker.rejectedSales);

  /// Only the clock is in the way, so this will clear on its own tonight.
  bool get clearsOnItsOwn =>
      holds.isNotEmpty &&
      holds.every((h) =>
          h.blocker == UpdateBlocker.serviceHours ||
          h.blocker == UpdateBlocker.soleTillInService ||
          h.blocker == UpdateBlocker.saleInProgress);

  String get reason =>
      holds.isEmpty ? 'Safe to install.' : holds.map((h) => h.reason).join(' ');

  @override
  String toString() => reason;
}

/// Decides whether installing right now is safe.
///
/// An update that lands mid-service, or while the till still holds sales that never
/// reached the server, costs the restaurant real money: the first empties the
/// counter during a rush, the second can lose the takings outright.
class UpdateGate {
  const UpdateGate({this.hours = const ServiceHours()});

  final ServiceHours hours;

  /// [mandatory] is the server saying this build fixes something that cannot wait.
  /// It buys an exception from the clock and nothing else.
  UpdateDecision evaluate(TillState till, {bool mandatory = false}) {
    final holds = <UpdateHold>[];

    if (till.pendingSales > 0) {
      // Never overridden, at any severity. An install replaces the binary and can
      // fail its migration; the only copy of these sales is on this device.
      holds.add(UpdateHold(
        UpdateBlocker.unsyncedSales,
        '${_sales(till.pendingSales)} not reached the server yet.',
      ));
    }

    if (till.rejectedSales > 0) {
      // Each one is money missing from the books. Updating over the top loses the
      // evidence of what happened along with the payload.
      holds.add(UpdateHold(
        UpdateBlocker.rejectedSales,
        '${_sales(till.rejectedSales)} been refused by the server and must be '
            'cleared by support.',
      ));
    }

    if (till.saleInProgress) {
      holds.add(const UpdateHold(
        UpdateBlocker.saleInProgress,
        'A sale is open on this till.',
      ));
    }

    if (hours.contains(till.localTime)) {
      if (!mandatory) {
        holds.add(UpdateHold(
          UpdateBlocker.serviceHours,
          'The shop is trading; updates wait until after '
          '${_hh(hours.closesAtHour)}.',
        ));
      } else if (till.soleTill) {
        // The override exists because a second till keeps taking money through the
        // restart. Alone, taking the override means the shop simply stops selling.
        holds.add(const UpdateHold(
          UpdateBlocker.soleTillInService,
          'This is the only till trading; the security update installs at closing.',
        ));
      }
    }

    return holds.isEmpty ? const UpdateDecision.allow() : UpdateDecision(holds);
  }

  static String _sales(int n) => n == 1 ? '1 sale has' : '$n sales have';

  static String _hh(int hour) => '${hour.toString().padLeft(2, '0')}:00';
}
