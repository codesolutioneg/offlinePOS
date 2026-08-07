/// PIN rules. Deliberately separate from the hasher so they can be tested without
/// paying the cost of a slow KDF.
class PinPolicy {
  const PinPolicy({
    this.minLength = 4,
    this.maxLength = 6,
    this.maxAttempts = 5,
    this.lockout = const Duration(minutes: 5),
  });

  final int minLength;
  final int maxLength;

  /// A payment terminal gets an attempt limit. This is not negotiable: a 6-digit
  /// PIN is a million candidates, which is nothing without one.
  final int maxAttempts;
  final Duration lockout;

  bool isWellFormed(String pin) =>
      pin.length >= minLength &&
      pin.length <= maxLength &&
      RegExp(r'^\d+$').hasMatch(pin);
}

/// Tracks failed attempts per cashier and applies the lockout.
class PinAttemptGuard {
  PinAttemptGuard(this.policy);

  final PinPolicy policy;
  final Map<String, int> _failures = {};
  final Map<String, DateTime> _lockedUntil = {};

  bool isLocked(String cashierId, {DateTime? now}) {
    final until = _lockedUntil[cashierId];
    if (until == null) return false;
    if ((now ?? DateTime.now()).isBefore(until)) return true;
    _lockedUntil.remove(cashierId);
    _failures.remove(cashierId);
    return false;
  }

  void recordFailure(String cashierId, {DateTime? now}) {
    final n = (_failures[cashierId] ?? 0) + 1;
    _failures[cashierId] = n;
    if (n >= policy.maxAttempts) {
      _lockedUntil[cashierId] = (now ?? DateTime.now()).add(policy.lockout);
    }
  }

  void recordSuccess(String cashierId) {
    _failures.remove(cashierId);
    _lockedUntil.remove(cashierId);
  }

  int failures(String cashierId) => _failures[cashierId] ?? 0;
}
