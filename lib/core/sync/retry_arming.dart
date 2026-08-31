import '../db/settings_store.dart';
import 'sync_service.dart';

/// The armed state of a failed batch push, kept in the settings table.
///
/// Key-value on purpose: no schema change, and a row that is simply absent is the
/// same answer as nothing armed, so a till that has never failed a close reads
/// exactly as it did before this existed.
class SettingsRetryArming implements RetryArmingStore {
  SettingsRetryArming(this._settings);

  final SettingsStore _settings;

  static const String _atKey = 'sync_retry_armed_at';
  static const String _reasonKey = 'sync_retry_armed_reason';
  static const String _stoppedKey = 'sync_retry_stopped_reason';

  @override
  ({DateTime armedAt, String reason})? read() {
    final at = _settings.getString(_atKey);
    if (at == null || at.isEmpty) return null;
    final armedAt = DateTime.tryParse(at);
    // An unparseable stamp is treated as no arming rather than as now. Dating it
    // now would hand a dead push a fresh window on every boot, which is the one
    // outcome the window exists to prevent.
    if (armedAt == null) return null;
    return (
      armedAt: armedAt.toUtc(),
      reason: _settings.getString(_reasonKey) ?? 'a batch push did not deliver',
    );
  }

  @override
  void write(DateTime armedAt, String reason) {
    _settings.setString(_atKey, armedAt.toUtc().toIso8601String());
    _settings.setString(_reasonKey, reason);
  }

  @override
  void clear() {
    _settings.setString(_atKey, null);
    _settings.setString(_reasonKey, null);
  }

  @override
  String? readStopped() => _settings.getString(_stoppedKey);

  @override
  void writeStopped(String reason) => _settings.setString(_stoppedKey, reason);

  @override
  void clearStopped() => _settings.setString(_stoppedKey, null);
}
