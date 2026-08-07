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
  /// is generated here and the old data becomes permanently unreadable. That is a
  /// deliberate, documented trade — the alternative, a key derivable without the
  /// keychain, is a key an attacker with the device can derive too. A till must be
  /// synced before a wipe, which is why enrolment happens while online. See
  /// docs/SECURITY.md.
  Future<String> getOrCreate() async {
    final existing = await _store.read();
    if (existing != null && existing.isNotEmpty) return existing;
    final key = _generate();
    await _store.write(key);
    return key;
  }

  static String _generate() {
    final bytes = List<int>.generate(32, (_) => _rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
