import '../db/database.dart';

/// Where a till sends its sales, configured at runtime on the device.
///
/// url, db and login are not secrets. The password is here only to make a
/// single-operator local test convenient; a real fleet must not keep a shared Odoo
/// credential on every till, so production authenticates to a backend that holds
/// the one login and this table stays empty. See docs/SECURITY.md.
class OdooEndpoint {
  const OdooEndpoint({
    required this.baseUrl,
    required this.db,
    required this.login,
    this.password,
  });

  final String baseUrl;
  final String db;
  final String login;
  final String? password;

  bool get isComplete =>
      baseUrl.trim().isNotEmpty && db.trim().isNotEmpty && login.trim().isNotEmpty;

  OdooEndpoint copyWith({String? baseUrl, String? db, String? login, String? password}) =>
      OdooEndpoint(
        baseUrl: baseUrl ?? this.baseUrl,
        db: db ?? this.db,
        login: login ?? this.login,
        password: password ?? this.password,
      );
}

/// Stores the single endpoint row. One row, id always 1.
class OdooEndpointStore {
  OdooEndpointStore(this._db);

  final Db _db;

  /// The configured endpoint, or null on a fresh till. Null means the outbox keeps
  /// accumulating, which is the correct offline default rather than an error.
  OdooEndpoint? load() {
    final rows = _db.raw.select('SELECT base_url, db, login, password FROM odoo_endpoint WHERE id = 1');
    if (rows.isEmpty) return null;
    final r = rows.first;
    return OdooEndpoint(
      baseUrl: r['base_url'] as String,
      db: r['db'] as String,
      login: r['login'] as String,
      password: r['password'] as String?,
    );
  }

  void save(OdooEndpoint e) {
    _db.raw.execute(
      '''
      INSERT INTO odoo_endpoint (id, base_url, db, login, password, updated_at)
      VALUES (1, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        base_url = excluded.base_url, db = excluded.db,
        login = excluded.login, password = excluded.password,
        updated_at = excluded.updated_at
      ''',
      [e.baseUrl.trim(), e.db.trim(), e.login.trim(), e.password,
       DateTime.now().toUtc().toIso8601String()],
    );
  }

  void clear() => _db.raw.execute('DELETE FROM odoo_endpoint WHERE id = 1');

  bool get isConfigured => load()?.isComplete ?? false;
}
