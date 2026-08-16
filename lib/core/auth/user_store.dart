import '../db/database.dart';

class Cashier {
  const Cashier({
    required this.id,
    required this.name,
    required this.pinSalt,
    required this.pinHash,
    this.role = 'cashier',
    this.active = true,
    this.totpSecret,
  });

  final String id;
  final String name;
  final String pinSalt;
  final String pinHash;
  final String role;
  final bool active;

  /// The base32 secret of this person's authenticator app, or null when they have
  /// no second factor. Only ever used to check a code they type; nothing derived
  /// from it leaves the device.
  final String? totpSecret;

  bool get isManager => role == 'manager';

  /// Whether approving with this account also takes a code from their phone.
  bool get hasSecondFactor => (totpSecret ?? '').isNotEmpty;
}

/// Cashiers as held on the till, so a shift change works with no network.
class UserStore {
  UserStore(this._db);

  final Db _db;

  void upsert(Cashier c) => _db.raw.execute(
        'INSERT INTO users (id, name, pin_salt, pin_hash, role, active, totp_secret) '
        'VALUES (?,?,?,?,?,?,?) '
        'ON CONFLICT(id) DO UPDATE SET name=excluded.name, pin_salt=excluded.pin_salt, '
        'pin_hash=excluded.pin_hash, role=excluded.role, active=excluded.active, '
        'totp_secret=excluded.totp_secret',
        [c.id, c.name, c.pinSalt, c.pinHash, c.role, c.active ? 1 : 0, c.totpSecret],
      );

  /// Turn a second factor on or off for one person without touching their PIN, so
  /// enrolling an authenticator is not a password reset.
  void setTotpSecret(String id, String? secret) => _db.raw.execute(
      'UPDATE users SET totp_secret = ? WHERE id = ?',
      [(secret ?? '').isEmpty ? null : secret, id]);

  /// Replaces the roster in one transaction, so a partial sync cannot leave the
  /// till with nobody able to sign in.
  void replaceAll(List<Cashier> users) {
    if (users.isEmpty) return;
    _db.raw.execute('BEGIN');
    try {
      _db.raw.execute('DELETE FROM users');
      for (final u in users) {
        upsert(u);
      }
      _db.raw.execute('COMMIT');
    } catch (_) {
      _db.raw.execute('ROLLBACK');
      rethrow;
    }
  }

  List<Cashier> active() => _db.raw
      .select('SELECT * FROM users WHERE active = 1 ORDER BY name')
      .map(_map)
      .toList();

  /// Everyone, active or not, so a manager can see and reactivate a cashier who was
  /// deactivated; without this a deactivated cashier is stranded off the roster.
  List<Cashier> all() =>
      _db.raw.select('SELECT * FROM users ORDER BY active DESC, name').map(_map).toList();

  Cashier? byId(String id) {
    final rows = _db.raw.select('SELECT * FROM users WHERE id = ?', [id]);
    return rows.isEmpty ? null : _map(rows.first);
  }

  bool get isEmpty =>
      (_db.raw.select('SELECT COUNT(*) c FROM users').first['c'] as int) == 0;

  Cashier _map(Map<String, Object?> r) => Cashier(
        id: r['id'] as String,
        name: r['name'] as String,
        pinSalt: r['pin_salt'] as String,
        pinHash: r['pin_hash'] as String,
        role: r['role'] as String,
        active: (r['active'] as int) == 1,
        totpSecret: r['totp_secret'] as String?,
      );
}
