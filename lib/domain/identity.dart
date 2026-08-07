import 'dart:math';

/// Client-generated identity.
///
/// Every record the till creates gets one of these at creation and keeps it for
/// life. The server may return its own id, but that is stored as a reference, never
/// as the identity. This is what makes the outbox safe to replay: pushing the same
/// order twice is the same order, so sync needs no merge and no conflict resolution.
class Uuid {
  static final Random _rng = Random.secure();
  static const String _hex = '0123456789abcdef';

  /// RFC 4122 version 4, from a cryptographically secure source.
  static String v4() {
    final b = List<int>.generate(16, (_) => _rng.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40; // version 4
    b[8] = (b[8] & 0x3f) | 0x80; // variant 10
    final s = StringBuffer();
    for (var i = 0; i < 16; i++) {
      if (i == 4 || i == 6 || i == 8 || i == 10) s.write('-');
      s..write(_hex[(b[i] >> 4) & 0x0f])..write(_hex[b[i] & 0x0f]);
    }
    return s.toString();
  }
}
