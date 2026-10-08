import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The cloud backup's secrets: the device token and the shop's recovery key.
///
/// Kept in the platform keychain rather than in app_settings, because the
/// database is what gets backed up and copied around: a token or a recovery key
/// inside it would travel with every copy.
abstract interface class CloudSecrets {
  Future<String?> read(String name);

  /// Null or empty removes it.
  Future<void> write(String name, String? value);
}

class SecureCloudSecrets implements CloudSecrets {
  SecureCloudSecrets([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static String _key(String name) => 'offlinepos_cloud_${name}_v1';

  @override
  Future<String?> read(String name) => _storage.read(key: _key(name));

  @override
  Future<void> write(String name, String? value) => value == null || value.isEmpty
      ? _storage.delete(key: _key(name))
      : _storage.write(key: _key(name), value: value);
}

/// For the suites, and for a build with no keychain.
class MemoryCloudSecrets implements CloudSecrets {
  final Map<String, String> held = {};

  @override
  Future<String?> read(String name) async => held[name];

  @override
  Future<void> write(String name, String? value) async {
    if (value == null || value.isEmpty) {
      held.remove(name);
    } else {
      held[name] = value;
    }
  }
}
