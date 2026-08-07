import '../../domain/identity.dart';
import 'database.dart';

/// What this till calls itself, and the cached enrolment beside it.
///
/// The id is generated on the device and kept forever. A constant compiled into
/// the app makes every till in a shop report the same one, which means two tills
/// push orders that reconciliation cannot tell apart and support cannot say which
/// machine is behind. A client-generated uuid needs no server to be unique, which
/// is the same reasoning that makes the outbox safe to replay.
class DeviceStore {
  DeviceStore(this._db);

  final Db _db;

  static const String _deviceIdKey = 'device_id';

  /// This till's id, created on first call.
  String deviceId() {
    final existing = _read(_deviceIdKey);
    if (existing != null) return existing;
    final id = Uuid.v4();
    _write(_deviceIdKey, id);
    return id;
  }

  String? _read(String key) {
    final rows = _db.raw
        .select('SELECT value FROM device_enrolment WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  void _write(String key, String value) => _db.raw.execute(
        'INSERT INTO device_enrolment (key, value) VALUES (?,?) '
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        [key, value],
      );
}
