import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// The shop's key for its cloud backups: 32 random bytes, generated on the till.
///
/// The server stores what it is sent and never sees this key, so a copy of the
/// server's disk is worth nothing without it. The other side of that: a shop that
/// loses the key cannot open its own backups, which is why the owner is shown it
/// once to write down.
///
/// Written as Crockford base32 in groups of four (no I, L, O or U, so it reads
/// back off paper without guessing), and read back ignoring case, spaces and
/// dashes.
class RecoveryKey {
  RecoveryKey._(this.bytes);

  final Uint8List bytes;

  static const int length = 32;
  static const String _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  static final Random _rng = Random.secure();

  factory RecoveryKey.generate() => RecoveryKey._(Uint8List.fromList(
      List<int>.generate(length, (_) => _rng.nextInt(256))));

  /// Throws [FormatException] on anything that is not a whole key.
  factory RecoveryKey.parse(String text) {
    final clean = text
        .toUpperCase()
        .replaceAll(RegExp(r'[\s-]'), '')
        .replaceAll('O', '0')
        .replaceAll(RegExp('[IL]'), '1');
    final bits = <int>[];
    for (final ch in clean.split('')) {
      final v = _alphabet.indexOf(ch);
      if (v < 0) throw FormatException('not a recovery key character: $ch');
      for (var i = 4; i >= 0; i--) {
        bits.add((v >> i) & 1);
      }
    }
    if (bits.length < length * 8 || bits.length >= length * 8 + 5) {
      throw const FormatException('a recovery key is 52 characters');
    }
    final out = Uint8List(length);
    for (var i = 0; i < length * 8; i++) {
      out[i ~/ 8] |= bits[i] << (7 - i % 8);
    }
    return RecoveryKey._(out);
  }

  /// `XXXX-XXXX-…`, 52 characters in 13 groups.
  String format() {
    final buf = StringBuffer();
    var acc = 0, held = 0, written = 0;
    void put(int v) {
      if (written > 0 && written % 4 == 0) buf.write('-');
      buf.write(_alphabet[v]);
      written++;
    }

    for (final b in bytes) {
      acc = (acc << 8) | b;
      held += 8;
      while (held >= 5) {
        held -= 5;
        put((acc >> held) & 31);
      }
    }
    if (held > 0) put((acc << (5 - held)) & 31);
    return buf.toString();
  }

  /// A short public name for the key, sent with every backup so a restore can say
  /// which key a backup needs before trying to open it. Says nothing about the key.
  String get id =>
      crypto.sha256.convert([...'offlinepos-backup-key'.codeUnits, ...bytes])
          .toString()
          .substring(0, 12);
}
