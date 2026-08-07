import 'dart:math';

import 'auth_service.dart';
import 'user_store.dart';

/// Gets a cashier onto a till that has none, without putting a credential in the
/// binary.
///
/// A literal PIN in source is the same PIN on every till at every client, it is
/// recoverable from the APK by anyone running reFlutter, and it comes back after
/// every wipe. docs/SECURITY.md forbids it outright: "No secret, key or credential
/// in the repo or the binary."
///
/// So the PIN is random, per device, and shown once on the sign-in screen. It is
/// regenerated on every launch for as long as the till is still on it. That is
/// deliberate: nothing has to be stored in the clear to be shown again, and a
/// provisioning code nobody wrote down costs a restart rather than bricking the
/// till. The arrangement ends the moment a real roster arrives, because this
/// account is then no longer the only one.
class BootstrapCashier {
  /// Reserved. A roster from the server must never use it.
  static const String id = 'setup';

  static const String name = 'Setup';

  static final Random _rng = Random.secure();

  /// Whether [roster] is still nothing but the provisioning account.
  static bool stillNeeded(List<Cashier> roster) =>
      roster.isEmpty || (roster.length == 1 && roster.single.id == id);

  /// Six digits from a secure source. Uniform, so no digit is likelier than
  /// another and the code cannot be narrowed by knowing how it was made.
  static String newPin() =>
      List.generate(6, (_) => _rng.nextInt(10)).join();

  /// Enrols the provisioning account with a fresh PIN and returns it, for showing
  /// to whoever is standing at the till. Returns null when a real roster exists.
  static Future<String?> ensure(AuthService auth, UserStore users) async {
    if (!stillNeeded(users.active())) return null;
    final pin = newPin();
    await auth.enrol(id: id, name: name, pin: pin);
    return pin;
  }
}
