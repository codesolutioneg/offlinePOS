import 'dart:convert';
import 'dart:io';

/// Where the reports-site sync stands on this till.
///
/// In its own file beside pos.db, for the reason the backup's state is (a write
/// to the database would be one more change to send), and apart from the
/// backup's file so neither service can save over what the other just wrote.
class CloudSyncState {
  CloudSyncState({
    this.historyFor,
    Map<String, String>? lookupShas,
    this.lastSuccessAt,
    this.lastTryAt,
    this.lastError,
  }) : lookupShas = lookupShas ?? {};

  /// A digest of the token the till's whole history was queued for. A new
  /// pairing has a new token, and the server it points at has none of it yet.
  String? historyFor;

  /// The digest of each lookup last sent, so an unchanged menu is not sent
  /// every minute.
  final Map<String, String> lookupShas;

  DateTime? lastSuccessAt;
  DateTime? lastTryAt;
  String? lastError;

  Map<String, dynamic> toJson() => {
        'history_for': historyFor,
        'lookup_shas': lookupShas,
        'last_success_at': lastSuccessAt?.toUtc().toIso8601String(),
        'last_try_at': lastTryAt?.toUtc().toIso8601String(),
        'last_error': lastError,
      };

  factory CloudSyncState.fromJson(Map<String, dynamic> m) => CloudSyncState(
        historyFor: m['history_for'] as String?,
        lookupShas: {
          for (final e in ((m['lookup_shas'] as Map?) ?? const {}).entries)
            '${e.key}': '${e.value}',
        },
        lastSuccessAt:
            DateTime.tryParse(m['last_success_at'] as String? ?? '')?.toLocal(),
        lastTryAt: DateTime.tryParse(m['last_try_at'] as String? ?? '')?.toLocal(),
        lastError: m['last_error'] as String?,
      );
}

abstract interface class CloudSyncStateStore {
  CloudSyncState load();
  void save(CloudSyncState state);
}

class FileCloudSyncStateStore implements CloudSyncStateStore {
  FileCloudSyncStateStore(this.path);

  final String path;

  @override
  CloudSyncState load() {
    try {
      final file = File(path);
      if (!file.existsSync()) return CloudSyncState();
      return CloudSyncState.fromJson(
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>);
    } catch (_) {
      // A torn write costs the history being queued once more, which the
      // server takes as overwrites.
      return CloudSyncState();
    }
  }

  @override
  void save(CloudSyncState state) {
    final part = File('$path.part');
    part.writeAsStringSync(jsonEncode(state.toJson()), flush: true);
    part.renameSync(path);
  }
}

class MemoryCloudSyncStateStore implements CloudSyncStateStore {
  CloudSyncState state = CloudSyncState();

  @override
  CloudSyncState load() => CloudSyncState.fromJson(state.toJson());

  @override
  void save(CloudSyncState s) => state = CloudSyncState.fromJson(s.toJson());
}
