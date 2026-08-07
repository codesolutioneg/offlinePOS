import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'db_key.dart';

/// Keeps the database key in the operating system's own secure store, so it is not
/// sitting in a file next to the data it protects.
class SecureKeyStore implements KeyStore {
  // Defaults are correct for our use: encrypted storage is the default on Android
  // in this version, and on Windows the key lives in the credential store. A
  // device key is deliberately not cloud-synced.
  SecureKeyStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _key = 'offlinepos_db_key_v1';

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String key) => _storage.write(key: _key, value: key);
}
