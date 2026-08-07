import '../db/database.dart';

class Cashier {
  const Cashier({
    required this.id,
    required this.name,
    required this.pinSalt,
    required this.pinHash,
    this.role = 'cashier',
    this.active = true,
  });

  final String id;
  final String name;
  final String pinSalt;
  final String pinHash;
  final String role;
  final bool active;

  bool get isManager => role == 'manager';
}

/// Cashiers as held on the till, so a shift change works with no network.
class UserStore {
  UserStore(this._db);

  final Db _db;

  void upsert(Cashier c) => _db.raw.execute(
        'INSERT INTO users (id, name, pin_salt, pin_hash, role, active) VALUES (?,?,?,?,?,?) '
        'ON CONFLICT(id) DO UPDATE SET name=excluded.name, pin_salt=excluded.pin_salt, '
        'pin_hash=excluded.pin_hash, role=excluded.role, active=excluded.active',
        [c.id, c.name, c.pinSalt, c.pinHash, c.role, c.active ? 1 : 0],
      );

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
      );
}
