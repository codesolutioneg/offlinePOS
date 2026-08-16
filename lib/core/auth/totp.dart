import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Time-based one-time codes (RFC 6238), computed and checked on the device.
///
/// The whole point of this second factor is that it needs nothing but a clock: a
/// manager approving a void in a shop with the line down gets the same six digits
/// off their phone that this code expects, because both sides derive them from the
/// shared secret and the time. Nothing here reaches the network, ever.
///
/// It sits BESIDE the PIN, never instead of it: the Argon2id hash and the attempt
/// lockout are unchanged, and a code is only ever asked for after a PIN has already
/// been verified.
class Totp {
  const Totp._();

  /// The defaults every authenticator app ships with, so a secret can be added to
  /// one by scanning or typing it with no extra parameters.
  static const int digits = 6;
  static const Duration step = Duration(seconds: 30);

  /// How many steps either side of now are accepted. One step (30s) covers a phone
  /// and a till whose clocks have drifted apart, and a manager who starts typing as
  /// the code rolls over, without widening the window to something guessable.
  static const int drift = 1;

  static const String _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  /// A typed or pasted secret in the form this class stores, or null when it is not
  /// a usable base32 secret. Spaces, dashes, lower case and the '=' padding an app
  /// prints are all accepted, because that is how the string arrives off a screen.
  static String? normaliseSecret(String raw) {
    final cleaned =
        raw.toUpperCase().replaceAll(RegExp('[^A-Z2-7]'), '');
    if (cleaned.length < 16) return null;
    return cleaned;
  }

  /// The code this secret produces at [at]. Exposed so a manager can be shown the
  /// current code while enrolling and confirm the two sides agree.
  static String codeAt(String secret, DateTime at) {
    final key = _decodeBase32(secret);
    if (key.isEmpty) return '';
    return _code(key, at.toUtc().millisecondsSinceEpoch ~/ step.inMilliseconds);
  }

  /// Whether [code] is the code for [secret] right now (or one step either side).
  ///
  /// A blank or malformed secret never verifies, so a user with no second factor
  /// configured cannot be approved by leaving the field empty.
  static bool verify(String secret, String code, {DateTime? at}) {
    final typed = code.replaceAll(RegExp(r'\D'), '');
    if (typed.length != digits) return false;
    final key = _decodeBase32(secret);
    if (key.isEmpty) return false;
    final counter =
        (at ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ step.inMilliseconds;
    var ok = false;
    for (var i = -drift; i <= drift; i++) {
      // No early return: every candidate is compared so the time this takes says
      // nothing about which step matched.
      if (_equal(_code(key, counter + i), typed)) ok = true;
    }
    return ok;
  }

  /// HMAC-SHA1 of the counter, dynamically truncated to [digits], as RFC 4226
  /// defines it and every authenticator app implements it.
  static String _code(List<int> key, int counter) {
    final message = Uint8List(8);
    var c = counter;
    for (var i = 7; i >= 0; i--) {
      message[i] = c & 0xff;
      c >>= 8;
    }
    final mac = Hmac(sha1, key).convert(message).bytes;
    final offset = mac[mac.length - 1] & 0x0f;
    final binary = ((mac[offset] & 0x7f) << 24) |
        ((mac[offset + 1] & 0xff) << 16) |
        ((mac[offset + 2] & 0xff) << 8) |
        (mac[offset + 3] & 0xff);
    final mod = binary % 1000000;
    return mod.toString().padLeft(digits, '0');
  }

  /// A comparison whose duration does not depend on where the two differ.
  static bool _equal(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// Base32 (RFC 4648) to bytes. An empty list for anything unusable, which every
  /// caller reads as "no second factor here".
  static List<int> _decodeBase32(String secret) {
    final s = normaliseSecret(secret);
    if (s == null) return const [];
    final out = <int>[];
    var buffer = 0;
    var bits = 0;
    for (final ch in s.codeUnits) {
      final v = _alphabet.indexOf(String.fromCharCode(ch));
      if (v < 0) return const [];
      buffer = (buffer << 5) | v;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.add((buffer >> bits) & 0xff);
      }
    }
    return out;
  }
}
