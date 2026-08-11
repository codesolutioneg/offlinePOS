import '../../domain/catalogue.dart';
import '../../domain/identity.dart';
import 'database.dart';

/// Customers added on the till, held separately from the read-only partners pulled
/// from Odoo. Lets a cashier capture a delivery or regular customer on device
/// without waiting for a catalogue sync, and reuse them from the picker.
class CustomerStore {
  CustomerStore(this._db);

  final Db _db;

  /// Create a local customer, returning it as a [Customer] with its local id
  /// encoded negative so it never collides with a positive Odoo partner id.
  Customer add({required String name, String? phone, String? address}) {
    final uuid = Uuid.v4();
    _db.raw.execute(
      'INSERT INTO local_customers (id, name, phone, address, created_at) VALUES (?,?,?,?,?)',
      [uuid, name, phone, address, DateTime.now().toUtc().toIso8601String()],
    );
    return _toCustomer(uuid, name, phone);
  }

  void update(String id, {required String name, String? phone, String? address}) =>
      _db.raw.execute(
        'UPDATE local_customers SET name = ?, phone = ?, address = ? WHERE id = ?',
        [name, phone, address, id],
      );

  void remove(String id) =>
      _db.raw.execute('DELETE FROM local_customers WHERE id = ?', [id]);

  /// Local customers, optionally filtered by name or phone, newest first.
  List<Customer> search({String? query, int limit = 50}) {
    final q = (query ?? '').trim();
    final rows = q.isEmpty
        ? _db.raw.select(
            'SELECT * FROM local_customers ORDER BY created_at DESC LIMIT ?', [limit])
        : _db.raw.select(
            'SELECT * FROM local_customers WHERE name LIKE ? OR phone LIKE ? '
            'ORDER BY created_at DESC LIMIT ?',
            ['%$q%', '%$q%', limit]);
    return rows
        .map((r) => _toCustomer(r['id'] as String, r['name'] as String, r['phone'] as String?,
            address: r['address'] as String?))
        .toList();
  }

  /// The raw row for an id, for the edit form (address is not on [Customer]).
  Map<String, Object?>? byId(String id) {
    final rows = _db.raw.select('SELECT * FROM local_customers WHERE id = ?', [id]);
    return rows.isEmpty ? null : rows.first;
  }

  // A local customer carries a negative synthetic id (from the uuid hash) so the
  // rest of the app, which keys customers by int id, can hold it without clashing
  // with an Odoo partner. The order still sends the name/phone, which is what the
  // module actually books against.
  Customer _toCustomer(String uuid, String name, String? phone, {String? address}) =>
      Customer(id: -(uuid.hashCode.abs()), name: name, phone: phone);
}
