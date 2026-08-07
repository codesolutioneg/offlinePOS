import 'dart:math' as math;

/// PIN rules. Deliberately separate from the hasher so they can be tested without
/// paying the cost of a slow KDF.
class PinPolicy {
  const PinPolicy({
    this.minLength = 4,
    this.maxLength = 6,
    this.maxAttempts = 5,
    this.lockout = const Duration(minutes: 5),
    this.maxLockout = const Duration(hours: 2),
  });

  final int minLength;
  final int maxLength;

  /// A payment terminal gets an attempt limit. This is not negotiable: a 6-digit
  /// PIN is a million candidates, which is nothing without one.
  final int maxAttempts;

  /// The first lockout. Each further failure past the limit doubles it.
  final Duration lockout;

  /// Where the doubling stops. Long enough that guessing is pointless, short
  /// enough that a cashier who genuinely forgot is not locked out for a shift.
  final Duration maxLockout;

  bool isWellFormed(String pin) =>
      pin.length >= minLength &&
      pin.length <= maxLength &&
      RegExp(r'^\d+$').hasMatch(pin);

  /// Escalating backoff, as docs/SECURITY.md requires: a flat retry window is a
  /// rate limit, not a deterrent, because an attacker just waits it out and keeps
  /// going at a fixed cost per batch.
  Duration lockoutAfter(int failures) {
    final over = failures - maxAttempts;
    if (over < 0) return Duration.zero;
    final scaled = lockout * math.pow(2, math.min(over, 20)).toDouble();
    return scaled > maxLockout ? maxLockout : scaled;
  }
}

/// Where failed attempts are counted.
///
/// An attempt limit that lives in memory is not an attempt limit: force-quitting
/// the app resets it, and a 4-digit PIN is then ten thousand tries from open. This
/// exists so the count can outlive the process.
abstract interface class AttemptStore {
  int failures(String cashierId);
  DateTime? lockedUntil(String cashierId);
  void put(String cashierId, {required int failures, DateTime? lockedUntil});
  void clear(String cashierId);
}

/// Counts that vanish with the process. For tests, and for callers with no
/// database. Never for a till.
class MemoryAttemptStore implements AttemptStore {
  final Map<String, int> _failures = {};
  final Map<String, DateTime> _lockedUntil = {};

  @override
  int failures(String cashierId) => _failures[cashierId] ?? 0;

  @override
  DateTime? lockedUntil(String cashierId) => _lockedUntil[cashierId];

  @override
  void put(String cashierId, {required int failures, DateTime? lockedUntil}) {
    _failures[cashierId] = failures;
    if (lockedUntil == null) {
      _lockedUntil.remove(cashierId);
    } else {
      _lockedUntil[cashierId] = lockedUntil;
    }
  }

  @override
  void clear(String cashierId) {
    _failures.remove(cashierId);
    _lockedUntil.remove(cashierId);
  }
}

/// Tracks failed attempts per cashier and applies the lockout.
class PinAttemptGuard {
  PinAttemptGuard(this.policy, {AttemptStore? store})
      : _store = store ?? MemoryAttemptStore();

  final PinPolicy policy;
  final AttemptStore _store;

  bool isLocked(String cashierId, {DateTime? now}) {
    final until = _store.lockedUntil(cashierId);
    if (until == null) return false;
    if ((now ?? DateTime.now()).isBefore(until)) return true;
    // Served their time. The count goes with it, so the next mistake starts the
    // escalation over rather than jumping straight back to the longest wait.
    _store.clear(cashierId);
    return false;
  }

  void recordFailure(String cashierId, {DateTime? now}) {
    final n = _store.failures(cashierId) + 1;
    final lockout = policy.lockoutAfter(n);
    _store.put(
      cashierId,
      failures: n,
      lockedUntil:
          lockout == Duration.zero ? null : (now ?? DateTime.now()).add(lockout),
    );
  }

  void recordSuccess(String cashierId) => _store.clear(cashierId);

  int failures(String cashierId) => _store.failures(cashierId);

  /// When this cashier can try again. Null when they are not locked out.
  DateTime? lockedUntil(String cashierId) => _store.lockedUntil(cashierId);
}
