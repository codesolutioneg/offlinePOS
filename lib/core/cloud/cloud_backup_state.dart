import 'dart:convert';
import 'dart:io';

/// Where the cloud backup stands on this till.
///
/// Kept in a file beside pos.db, not in it. Every attempt writes here, and a
/// write to the database would make the next snapshot differ from the last, so
/// an idle till would upload every hour. It also keeps a restored database from
/// bringing another till's server and pairing along with it.
class CloudBackupState {
  CloudBackupState({
    this.url,
    this.shopName,
    this.lastDbSha,
    this.lastSuccessAt,
    this.lastTryAt,
    this.lastError,
  });

  String? url;
  String? shopName;

  /// The database digest last uploaded, so an unchanged till is not sent again.
  String? lastDbSha;
  DateTime? lastSuccessAt;
  DateTime? lastTryAt;

  /// Why the last attempt failed, or null once one has gone through.
  String? lastError;

  Map<String, dynamic> toJson() => {
        'url': url,
        'shop_name': shopName,
        'last_db_sha': lastDbSha,
        'last_success_at': lastSuccessAt?.toUtc().toIso8601String(),
        'last_try_at': lastTryAt?.toUtc().toIso8601String(),
        'last_error': lastError,
      };

  factory CloudBackupState.fromJson(Map<String, dynamic> m) => CloudBackupState(
        url: m['url'] as String?,
        shopName: m['shop_name'] as String?,
        lastDbSha: m['last_db_sha'] as String?,
        lastSuccessAt:
            DateTime.tryParse(m['last_success_at'] as String? ?? '')?.toLocal(),
        lastTryAt: DateTime.tryParse(m['last_try_at'] as String? ?? '')?.toLocal(),
        lastError: m['last_error'] as String?,
      );
}

/// Reads and writes [CloudBackupState].
abstract interface class CloudBackupStateStore {
  CloudBackupState load();
  void save(CloudBackupState state);
}

class FileCloudBackupStateStore implements CloudBackupStateStore {
  FileCloudBackupStateStore(this.path);

  final String path;

  @override
  CloudBackupState load() {
    try {
      final file = File(path);
      if (!file.existsSync()) return CloudBackupState();
      return CloudBackupState.fromJson(
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>);
    } catch (_) {
      // A torn write costs one extra upload and a fresh pairing at worst.
      return CloudBackupState();
    }
  }

  @override
  void save(CloudBackupState state) {
    final part = File('$path.part');
    part.writeAsStringSync(jsonEncode(state.toJson()), flush: true);
    part.renameSync(path);
  }
}

class MemoryCloudBackupStateStore implements CloudBackupStateStore {
  CloudBackupState state = CloudBackupState();

  @override
  CloudBackupState load() => CloudBackupState.fromJson(state.toJson());

  @override
  void save(CloudBackupState s) => state = CloudBackupState.fromJson(s.toJson());
}
