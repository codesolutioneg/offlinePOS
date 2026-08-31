import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;

/// Why a request was turned away, so the log can tell a stranger from a till paired
/// to a different shop from a clock that drifted.
enum LanAuth { ok, missing, wrongKey, staleClock }

/// The shared secret the devices in one shop hold, and the stamp they put on every
/// request to each other.
///
/// The key never goes on the wire. A request carries the time it was made and an
/// HMAC of what it is asking for, so a device listening on the shop LAN learns
/// nothing it can reuse to ask its own questions, and a guest laptop cannot read the
/// tabs or push a floor plan.
///
/// What this does NOT do is hide the events. They travel as plain JSON over plain
/// HTTP, so a device that can capture traffic on the switch can still read a page it
/// caught. This is a pairing boundary, not secrecy; docs/LAN_SYNC.md says so plainly
/// rather than leaving anyone to assume otherwise. Replay is not defended either,
/// and does not need to be: a repeated pull re-reads, and a repeated notify re-applies
/// events that are idempotent on their uuid.
class LanCredential {
  LanCredential(String key, {DateTime Function()? now})
      : this.rotating(() => key, now: now);

  /// A credential that asks for the key at the moment of each request rather than
  /// holding the one it was born with, so a key replaced on the shop network screen
  /// is the key in force for the next request instead of at the next restart.
  ///
  /// Nothing else about the boundary moves: the key is still one shared secret, it
  /// is still never on the wire, and a device holding the previous one is turned
  /// away as an outsider, which is exactly what rotating a key is for.
  LanCredential.rotating(String Function() readKey, {DateTime Function()? now})
      : _readKey = readKey,
        _now = now ?? DateTime.now;

  /// The header the stamp travels in.
  static const String header = 'x-lan-auth';

  /// How far apart two tills' clocks may be before their requests stop verifying.
  /// Generous on purpose: a till whose clock drifted by a few minutes has to keep
  /// sharing, and when it finally does bite the refusal names the skew instead of
  /// looking like a network fault.
  static const Duration clockTolerance = Duration(minutes: 15);

  final String Function() _readKey;
  final DateTime Function() _now;

  /// The key [_mac] was built from, so the hash is set up once per key and not once
  /// per request: a till stamps and checks constantly and rotates a key almost
  /// never.
  String? _keyed;
  crypto.Hmac? _mac;

  /// The key this device is paired on right now.
  String get key => _readKey();

  /// A key for a shop that has none yet: 32 random bytes, url-safe so it survives
  /// being pasted into a settings field or read down a phone.
  static String newKey([Random? random]) {
    final source = random ?? Random.secure();
    return base64Url.encode(List<int>.generate(32, (_) => source.nextInt(256)));
  }

  /// The stamp for one request: when it was made, and proof it was made by someone
  /// holding the key.
  String stamp({
    required String method,
    required String path,
    String query = '',
    String body = '',
  }) {
    final at = _now().toUtc().millisecondsSinceEpoch;
    return '$at.${_sign(method, path, query, body, at)}';
  }

  /// Whether [presented] is a stamp this till accepts for this exact request.
  LanAuth check(
    String? presented, {
    required String method,
    required String path,
    String query = '',
    String body = '',
  }) {
    if (presented == null || presented.isEmpty) return LanAuth.missing;
    final split = presented.indexOf('.');
    if (split <= 0) return LanAuth.missing;
    final at = int.tryParse(presented.substring(0, split));
    if (at == null) return LanAuth.missing;
    final drift = (_now().toUtc().millisecondsSinceEpoch - at).abs();
    if (drift > clockTolerance.inMilliseconds) return LanAuth.staleClock;
    return _sameSecret(
            _sign(method, path, query, body, at), presented.substring(split + 1))
        ? LanAuth.ok
        : LanAuth.wrongKey;
  }

  /// The query as both sides agree to sign it, so the order a map happened to be
  /// built in cannot break a signature.
  static String canonicalQuery(Map<String, String> query) {
    final names = query.keys.toList()..sort();
    return [for (final name in names) '$name=${query[name]}'].join('&');
  }

  String _sign(String method, String path, String query, String body, int at) =>
      _hmac.convert(utf8.encode('$method\n$path\n$query\n$at\n$body')).toString();

  /// The hash for the key in force, rebuilt only when the key itself changed.
  crypto.Hmac get _hmac {
    final current = _readKey();
    if (_mac == null || current != _keyed) {
      _keyed = current;
      _mac = crypto.Hmac(crypto.sha256, utf8.encode(current));
    }
    return _mac!;
  }

  /// Compares in constant time. Returning at the first differing character would let
  /// a device that is free to keep guessing learn the expected digest one character
  /// at a time.
  static bool _sameSecret(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
