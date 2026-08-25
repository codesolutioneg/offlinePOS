import 'dart:math';

/// Where the database encryption key is kept between launches.
///
/// An interface so the app backs it with the platform keychain (DPAPI on Windows,
/// Keychain on macOS/iOS, Keystore on Android) while tests use an in-memory fake.
/// The key never leaves secure storage and is never written to the database, a
/// file, or a log.
abstract interface class KeyStore {
  Future<String?> read();
  Future<void> write(String key);
}

/// A raw 32-byte SQLCipher key as hex, generated once and then reused.
///
/// Raw hex (the `x'...'` PRAGMA form) rather than a passphrase, so SQLCipher uses
/// the bytes directly with no key-derivation step and there is no weak human secret
/// anywhere in the chain.
class DbKey {
  DbKey(this._store);

  final KeyStore _store;
  static final Random _rng = Random.secure();

  /// The existing key, or a freshly generated one saved for next time.
  ///
  /// The danger this method carries: if a database file already exists but its key
  /// has been lost from secure storage (keychain wiped, OS reinstalled), a new key
  /// would make the old data permanently unreadable. That the key is not
  /// recoverable is a deliberate, documented trade — the alternative, a key
  /// derivable without the keychain, is a key an attacker with the device can
  /// derive too. See docs/SECURITY.md.
  ///
  /// So when [databaseExists], a missing key is treated as a question rather than
  /// an answer. A till that opens as the machine boots can reach the keychain
  /// before the OS is serving it, and a "no key" answered that early, acted on,
  /// silently costs the shop every sale that had not synced. It is asked again,
  /// [attempts] times, and if the key is still absent this throws instead of
  /// minting a replacement: a till that will not open can be recovered from, and
  /// data encrypted under a discarded key cannot.
  Future<String> getOrCreate({
    bool databaseExists = false,
    int attempts = 5,
    Duration retryAfter = const Duration(seconds: 1),
    Future<void> Function(Duration) wait = _sleep,
  }) async {
    for (var attempt = 1; ; attempt++) {
      final existing = await _readQuietly();
      if (existing != null && existing.isNotEmpty) return existing;
      // A fresh till has nothing to protect: the first launch is meant to land here.
      if (!databaseExists) break;
      if (attempt >= attempts) throw MissingDatabaseKey(attempts);
      await wait(retryAfter);
    }
    final key = _generate();
    await _store.write(key);
    return key;
  }

  /// A keychain that throws is a keychain that has not answered yet, which on a
  /// retry is the same as an empty one.
  Future<String?> _readQuietly() async {
    try {
      return await _store.read();
    } catch (_) {
      return null;
    }
  }

  static Future<void> _sleep(Duration d) => Future<void>.delayed(d);

  static String _generate() {
    final bytes = List<int>.generate(32, (_) => _rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

/// The keychain has no key for a till that already has a database.
///
/// Raised rather than generating a new one, because a new key turns existing sales
/// into noise. Support can restore a key or accept the loss deliberately; this
/// code cannot make that call on a shop's behalf.
class MissingDatabaseKey implements Exception {
  const MissingDatabaseKey(this.attempts);

  final int attempts;

  @override
  String toString() =>
      'MissingDatabaseKey: the keychain did not return this till\'s database key '
      'in $attempts attempts, and a database already exists. Generating a new key '
      'would make it permanently unreadable, so it was not generated.';
}
