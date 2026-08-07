import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// Argon2id PIN hashing.
///
/// A PIN is 4-6 digits, so at most a million candidates. Against a fast hash
/// (`SHA-256(salt + pin)`) that is exhausted in milliseconds by anyone holding the
/// device, which is why the KDF must be deliberately slow. Tune [memory] and
/// [iterations] so one verification costs roughly 100 ms on the target hardware:
/// slow enough to make a search pointless, fast enough that a cashier does not wait.
class PinHasher {
  PinHasher({
    this.memory = 19 * 1024, // 19 MiB, the OWASP baseline for Argon2id
    this.iterations = 2,
    this.parallelism = 1,
    this.hashLength = 32,
  });

  final int memory;
  final int iterations;
  final int parallelism;
  final int hashLength;

  static final Random _rng = Random.secure();

  Argon2id get _kdf => Argon2id(
        memory: memory,
        iterations: iterations,
        parallelism: parallelism,
        hashLength: hashLength,
      );

  /// 16 bytes from a secure source, unique per cashier.
  static String newSalt() =>
      base64Encode(List<int>.generate(16, (_) => _rng.nextInt(256)));

  Future<String> hash(String pin, String saltB64) async {
    final key = await _kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(pin)),
      nonce: base64Decode(saltB64),
    );
    return base64Encode(await key.extractBytes());
  }

  /// Constant-time comparison, so a caller cannot learn the hash byte by byte from
  /// how long a rejection takes.
  Future<bool> verify(String pin, String saltB64, String expectedB64) async {
    final actual = base64Decode(await hash(pin, saltB64));
    final expected = base64Decode(expectedB64);
    if (actual.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < actual.length; i++) {
      diff |= actual[i] ^ expected[i];
    }
    return diff == 0;
  }
}
