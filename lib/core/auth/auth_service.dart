import '../audit/audit_log.dart';
import 'pin_hasher.dart';
import 'pin_policy.dart';
import 'totp.dart';
import 'user_store.dart';

sealed class AuthResult {
  const AuthResult();
}

class AuthOk extends AuthResult {
  const AuthOk(this.cashier);
  final Cashier cashier;
}

class AuthRejected extends AuthResult {
  const AuthRejected();
}

class AuthLockedOut extends AuthResult {
  const AuthLockedOut(this.until);
  final DateTime until;
}

class AuthMalformed extends AuthResult {
  const AuthMalformed();
}

/// Signing a cashier in, entirely on the device.
///
/// No network call anywhere on this path. A shift change during an outage is a
/// normal shift change, which is the difference between a till that keeps trading
/// and one that stops when the line does.
class AuthService {
  /// [attempts] is where the failure count lives. Left out it is in memory only,
  /// which means the lockout dies with the process; a till passes the durable one.
  AuthService({
    required UserStore users,
    required PinHasher hasher,
    required AuditLog audit,
    PinPolicy policy = const PinPolicy(),
    AttemptStore? attempts,
    DateTime Function()? now,
  })  : _users = users,
        _hasher = hasher,
        _audit = audit,
        _policy = policy,
        _guard = PinAttemptGuard(policy, store: attempts),
        _now = now ?? DateTime.now;

  final UserStore _users;
  final PinHasher _hasher;
  final AuditLog _audit;
  final PinPolicy _policy;
  final PinAttemptGuard _guard;
  final DateTime Function() _now;

  Cashier? _signedIn;
  Cashier? get signedIn => _signedIn;
  bool get isSignedIn => _signedIn != null;

  /// The lockout is per cashier, so one person fat-fingering their PIN cannot lock
  /// the whole till out during service.
  Future<AuthResult> unlock(String cashierId, String pin) async {
    if (!_policy.isWellFormed(pin)) return const AuthMalformed();

    final now = _now();
    if (_guard.isLocked(cashierId, now: now)) {
      _audit.record(cashierId, 'pin.locked_out');
      // The real end of the lockout, not a fresh window from now: the backoff
      // escalates, so recomputing it here would understate the wait and have the
      // screen count down to a moment that still rejects them.
      return AuthLockedOut(_guard.lockedUntil(cashierId)!);
    }

    final user = _users.byId(cashierId);
    if (user == null || !user.active) {
      // Same answer as a wrong PIN: a rejection must not reveal who exists.
      _guard.recordFailure(cashierId, now: now);
      _audit.record(cashierId, 'pin.rejected');
      return const AuthRejected();
    }

    final ok = await _hasher.verify(pin, user.pinSalt, user.pinHash);
    if (!ok) {
      _guard.recordFailure(cashierId, now: now);
      _audit.record(cashierId, 'pin.rejected');
      return const AuthRejected();
    }

    _guard.recordSuccess(cashierId);
    _signedIn = user;
    _audit.record(cashierId, 'pin.unlock');
    return AuthOk(user);
  }

  void signOut() {
    final who = _signedIn?.id;
    _signedIn = null;
    if (who != null) _audit.record(who, 'sign_out');
  }

  int failuresFor(String cashierId) => _guard.failures(cashierId);

  /// Enrol or update a cashier from a roster sync, hashing the PIN locally.
  /// Authorise a privileged action (discount, void, refund, drawer) with a manager
  /// PIN. Returns true if the PIN matches any active manager. A separate check from
  /// [unlock] because the signed-in cashier need not sign out to get approval.
  ///
  /// A manager who has enrolled an authenticator must also give its current [code].
  /// The second factor is checked only after their PIN has matched, so it adds a
  /// step and takes none away: a manager with no authenticator approves exactly as
  /// before, and a wrong code is a refusal rather than a fallback to the PIN alone.
  /// Every part of this is offline: the code comes from the clock, not a server.
  Future<bool> authorizeManager(String pin, {String? code}) async {
    if (!_policy.isWellFormed(pin)) return false;
    for (final m in _users.active().where((u) => u.isManager)) {
      if (!await _hasher.verify(pin, m.pinSalt, m.pinHash)) continue;
      if (m.hasSecondFactor && !Totp.verify(m.totpSecret!, code ?? '')) {
        // Named apart from a wrong PIN in the trail: the difference between a
        // stolen PIN being tried and a manager fumbling their phone is the whole
        // reason for the second factor.
        _audit.record(m.id, 'manager.totp_rejected');
        return false;
      }
      _audit.record(m.id, 'manager.authorized');
      return true;
    }
    _audit.record('unknown', 'manager.authorization_failed');
    return false;
  }

  /// Prove one particular cashier is standing at the till, without signing them in.
  ///
  /// What a shared till needs when one person picks up a tab another one opened:
  /// the owner unlocks their own tab and walks away again, and the shift stays with
  /// whoever is actually on the drawer. Counted against the same per-cashier
  /// lockout as [unlock], so this cannot be used to guess a PIN around it.
  Future<bool> authorizeCashier(String cashierId, String pin) async {
    if (!_policy.isWellFormed(pin)) return false;
    final now = _now();
    if (_guard.isLocked(cashierId, now: now)) {
      _audit.record(cashierId, 'pin.locked_out');
      return false;
    }
    final user = _users.byId(cashierId);
    if (user == null || !user.active) {
      // Same answer as a wrong PIN: a rejection must not reveal who exists.
      _guard.recordFailure(cashierId, now: now);
      _audit.record(cashierId, 'pin.rejected');
      return false;
    }
    if (!await _hasher.verify(pin, user.pinSalt, user.pinHash)) {
      _guard.recordFailure(cashierId, now: now);
      _audit.record(cashierId, 'pin.rejected');
      return false;
    }
    _guard.recordSuccess(cashierId);
    _audit.record(cashierId, 'cashier.authorized');
    return true;
  }
  /// Whether anyone who could approve an action on this till has a second factor,
  /// so the approval dialog knows whether to ask for a code at all. A shop that has
  /// enrolled none never sees the field.
  bool get managersUseSecondFactor =>
      _users.active().any((u) => u.isManager && u.hasSecondFactor);

  Future<Cashier> enrol({
    required String id,
    required String name,
    required String pin,
    String role = 'cashier',
  }) async {
    final salt = PinHasher.newSalt();
    final cashier = Cashier(
      id: id, name: name, role: role,
      pinSalt: salt, pinHash: await _hasher.hash(pin, salt),
      // Re-enrolling is how a PIN is reset, and a PIN reset must not quietly take
      // the second factor off the account it protects.
      totpSecret: _users.byId(id)?.totpSecret,
    );
    _users.upsert(cashier);
    return cashier;
  }
}
