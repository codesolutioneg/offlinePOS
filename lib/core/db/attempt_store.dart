import '../auth/pin_policy.dart';
import 'database.dart';

/// Failed PIN attempts on disk.
///
/// The lockout is only worth anything if it survives a force-quit. Someone holding
/// a stolen till can restart the app between guesses for free, and a 4-digit PIN is
/// ten thousand guesses.
class SqliteAttemptStore implements AttemptStore {
  SqliteAttemptStore(this._db);

  final Db _db;

  @override
  int failures(String cashierId) {
    final rows = _db.raw.select(
        'SELECT failures FROM auth_attempts WHERE cashier_id = ?', [cashierId]);
    return rows.isEmpty ? 0 : rows.first['failures'] as int;
  }

  @override
  DateTime? lockedUntil(String cashierId) {
    final rows = _db.raw.select(
        'SELECT locked_until FROM auth_attempts WHERE cashier_id = ?', [cashierId]);
    if (rows.isEmpty) return null;
    final value = rows.first['locked_until'];
    return value is String ? DateTime.tryParse(value) : null;
  }

  @override
  void put(String cashierId, {required int failures, DateTime? lockedUntil}) =>
      _db.raw.execute(
        'INSERT INTO auth_attempts (cashier_id, failures, locked_until) VALUES (?,?,?) '
        'ON CONFLICT(cashier_id) DO UPDATE SET '
        'failures = excluded.failures, locked_until = excluded.locked_until',
        [cashierId, failures, lockedUntil?.toIso8601String()],
      );

  @override
  void clear(String cashierId) => _db.raw
      .execute('DELETE FROM auth_attempts WHERE cashier_id = ?', [cashierId]);
}
