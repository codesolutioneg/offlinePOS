import '../../domain/delivery.dart';
import '../../domain/identity.dart';
import 'database.dart';

/// The delivery lists a shop edits on the device: zones with their charge, the
/// channels orders arrive through, and the drivers who take them out.
///
/// Local like every other store here, so a cashier picks a zone or a driver with
/// the line down exactly as they do with it up. Reads are synchronous because they
/// happen on a selling screen.
class DeliveryStore {
  DeliveryStore(this._db);

  final Db _db;

  // ── zones ────────────────────────────────────────────────────────

  /// Every zone, oldest first, which is the order the manager typed them in and
  /// usually reads near to far.
  /// Zones and channels read back in the order they were typed.
  ///
  /// Tie-broken on rowid rather than on the name: a Windows clock ticks in
  /// milliseconds at best, so two rows added in one breath share a created_at, and
  /// an alphabetical tiebreak silently reorders a manager's list on one platform
  /// and not the other.
  List<DeliveryZone> zones() => _db.raw
      .select('SELECT * FROM delivery_zones ORDER BY created_at, rowid')
      .map((r) => DeliveryZone(
            id: r['id'] as String,
            name: r['name'] as String,
            fee: (r['fee'] as num).toDouble(),
          ))
      .toList();

  DeliveryZone addZone({required String name, required double fee}) {
    final zone = DeliveryZone(id: Uuid.v4(), name: name.trim(), fee: fee < 0 ? 0 : fee);
    _db.raw.execute(
      'INSERT INTO delivery_zones (id, name, fee, created_at) VALUES (?,?,?,?)',
      [zone.id, zone.name, zone.fee, _now()],
    );
    return zone;
  }

  void updateZone(String id, {required String name, required double fee}) =>
      _db.raw.execute('UPDATE delivery_zones SET name = ?, fee = ? WHERE id = ?',
          [name.trim(), fee < 0 ? 0 : fee, id]);

  /// Forget a zone. Orders already taken keep the charge they were rung with, so
  /// removing one never re-prices a sale.
  void removeZone(String id) =>
      _db.raw.execute('DELETE FROM delivery_zones WHERE id = ?', [id]);

  // ── channels ─────────────────────────────────────────────────────

  List<DeliveryChannel> channels() => _db.raw
      .select('SELECT * FROM delivery_channels ORDER BY created_at, rowid')
      .map((r) => DeliveryChannel(
            id: r['id'] as String,
            name: r['name'] as String,
            partnerId: r['partner_id'] as int?,
          ))
      .toList();

  DeliveryChannel addChannel({required String name, int? partnerId}) {
    final channel =
        DeliveryChannel(id: Uuid.v4(), name: name.trim(), partnerId: partnerId);
    _db.raw.execute(
      'INSERT INTO delivery_channels (id, name, partner_id, created_at) VALUES (?,?,?,?)',
      [channel.id, channel.name, channel.partnerId, _now()],
    );
    return channel;
  }

  void updateChannel(String id, {required String name, int? partnerId}) =>
      _db.raw.execute(
          'UPDATE delivery_channels SET name = ?, partner_id = ? WHERE id = ?',
          [name.trim(), partnerId, id]);

  void removeChannel(String id) =>
      _db.raw.execute('DELETE FROM delivery_channels WHERE id = ?', [id]);

  // ── drivers ──────────────────────────────────────────────────────

  /// The drivers on file. [activeOnly] is what a picker wants; the settings screen
  /// asks for all of them so someone deactivated can be brought back.
  List<Driver> drivers({bool activeOnly = false}) => _db.raw
      .select(activeOnly
          ? 'SELECT * FROM drivers WHERE active = 1 ORDER BY name'
          : 'SELECT * FROM drivers ORDER BY active DESC, name')
      .map((r) => Driver(
            id: r['id'] as String,
            name: r['name'] as String,
            phone: r['phone'] as String?,
            active: (r['active'] as int) == 1,
          ))
      .toList();

  Driver addDriver({required String name, String? phone}) {
    final driver = Driver(id: Uuid.v4(), name: name.trim(), phone: _blankToNull(phone));
    _db.raw.execute(
      'INSERT INTO drivers (id, name, phone, active, created_at) VALUES (?,?,?,1,?)',
      [driver.id, driver.name, driver.phone, _now()],
    );
    return driver;
  }

  void updateDriver(String id,
          {required String name, String? phone, required bool active}) =>
      _db.raw.execute(
          'UPDATE drivers SET name = ?, phone = ?, active = ? WHERE id = ?',
          [name.trim(), _blankToNull(phone), active ? 1 : 0, id]);

  /// Take a driver out of the picker without losing the name the orders they
  /// already carried were stamped with.
  void setDriverActive(String id, bool active) => _db.raw
      .execute('UPDATE drivers SET active = ? WHERE id = ?', [active ? 1 : 0, id]);

  /// Insert or refresh one driver from a spreadsheet row.
  ///
  /// When [id] is set and already on file, name/phone/active are updated in place
  /// so a re-import keeps the same driver on old tickets. A new id (or none) adds
  /// a row; we keep the external id when given so the next export matches.
  Driver upsertDriver({
    String? id,
    required String name,
    String? phone,
    bool active = true,
  }) {
    final trimmed = name.trim();
    final phoneVal = _blankToNull(phone);
    final given = id?.trim();
    if (given != null && given.isNotEmpty) {
      final exists = _db.raw
          .select('SELECT 1 AS ok FROM drivers WHERE id = ? LIMIT 1', [given]);
      if (exists.isNotEmpty) {
        updateDriver(given, name: trimmed, phone: phoneVal, active: active);
        return Driver(
            id: given, name: trimmed, phone: phoneVal, active: active);
      }
      final driver =
          Driver(id: given, name: trimmed, phone: phoneVal, active: active);
      _db.raw.execute(
        'INSERT INTO drivers (id, name, phone, active, created_at) VALUES (?,?,?,?,?)',
        [driver.id, driver.name, driver.phone, active ? 1 : 0, _now()],
      );
      return driver;
    }
    final driver = addDriver(name: trimmed, phone: phoneVal);
    if (!active) setDriverActive(driver.id, false);
    return Driver(
        id: driver.id, name: driver.name, phone: driver.phone, active: active);
  }

  static String? _blankToNull(String? v) {
    final t = v?.trim() ?? '';
    return t.isEmpty ? null : t;
  }

  static String _now() => DateTime.now().toUtc().toIso8601String();
}
