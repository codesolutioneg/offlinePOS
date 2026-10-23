import 'dart:convert';

import 'package:crypto/crypto.dart';

/// A PIN carried over from Dishflow, in the form Dishflow stored it.
///
/// Dishflow keeps `SHA-256(salt || pin)` as hex beside a hex salt. That is not
/// what this till stores (see [PinHasher]: a fast hash of a six-digit PIN is
/// searched in milliseconds), and a hash cannot be turned into another hash. So
/// an imported account keeps Dishflow's figure only until its owner next types
/// the PIN: it is checked here once, and the caller replaces it with the till's
/// own hash on the spot.
class LegacyPin {
  LegacyPin._();

  static const _prefix = 'dishflow-sha256:';

  /// Whether [pinHash] is one of these rather than the till's own.
  static bool isLegacy(String pinHash) => pinHash.startsWith(_prefix);

  /// What goes in the `pin_hash` column for a Dishflow hash, so the scheme
  /// travels with the value and needs no column of its own.
  static String wrap(String hashHex) => '$_prefix${hashHex.trim().toLowerCase()}';

  /// Whether [hashHex] and [saltHex] are shaped like something Dishflow wrote.
  static bool isUsable(String hashHex, String saltHex) =>
      RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hashHex.trim()) &&
      _bytes(saltHex.trim()) != null;

  /// Whether [pin] is the one behind [stored]. Never throws: a salt or a hash
  /// this cannot read is simply a PIN that does not match.
  static bool verify(String pin, String saltHex, String stored) {
    if (!isLegacy(stored)) return false;
    final salt = _bytes(saltHex.trim());
    if (salt == null) return false;
    final actual =
        sha256.convert([...salt, ...utf8.encode(pin)]).toString();
    final expected = stored.substring(_prefix.length);
    if (actual.length != expected.length) return false;
    // Constant-time, for the reason [Argon2idPinHasher.verify] is.
    var diff = 0;
    for (var i = 0; i < actual.length; i++) {
      diff |= actual.codeUnitAt(i) ^ expected.codeUnitAt(i);
    }
    return diff == 0;
  }

  static List<int>? _bytes(String hex) {
    if (hex.isEmpty || hex.length.isOdd) return null;
    final out = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      final b = int.tryParse(hex.substring(i, i + 2), radix: 16);
      if (b == null) return null;
      out.add(b);
    }
    return out;
  }
}
