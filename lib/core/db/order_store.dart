import 'dart:convert';

import '../../domain/order.dart';
import 'database.dart';

/// Orders on disk. Every mutation is written immediately, not at payment, so a
/// half-rung sale survives the app being killed.
class OrderStore {
  OrderStore(this._db);

  final Db _db;

  void save(Order order) {
    _db.raw.execute(
      '''
      INSERT INTO orders (uuid, device_id, cashier_id, created_at, state, server_id, total, payload)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(uuid) DO UPDATE SET
        state = excluded.state, server_id = excluded.server_id,
        total = excluded.total, payload = excluded.payload
      ''',
      [
        order.uuid,
        order.deviceId,
        order.cashierId,
        order.createdAt.toIso8601String(),
        order.state.name,
        order.serverId,
        order.total,
        jsonEncode(order.toMap()),
      ],
    );
  }

  Order? byUuid(String uuid) {
    final rows = _db.raw.select('SELECT payload FROM orders WHERE uuid = ?', [uuid]);
    if (rows.isEmpty) return null;
    return Order.fromMap(jsonDecode(rows.first['payload'] as String) as Map<String, dynamic>);
  }

  /// Unfinished sales, oldest first. This is what the till restores on launch so a
  /// cashier gets their order back after a crash or a closed window.
  List<Order> drafts() => _query("state = 'draft'");

  /// Orders parked on a table or tab, waiting to be recalled and paid. The open
  /// tabs a cashier switches between during a dine-in service.
  List<Order> held() => _query("state = 'held'");

  /// Paid but not yet confirmed by the server.
  List<Order> awaitingSync() => _query("state = 'paid'");

  /// Completed sales, newest first, for the history / reprint browser. Includes
  /// both paid-not-yet-synced and synced, so a sale shows up the instant it is
  /// taken, not only after the server confirms.
  List<Order> recent({int limit = 50}) => _db.raw
      .select(
          "SELECT payload FROM orders WHERE state IN ('paid','synced') "
          'ORDER BY created_at DESC LIMIT ?',
          [limit])
      .map((r) =>
          Order.fromMap(jsonDecode(r['payload'] as String) as Map<String, dynamic>))
      .toList();

  List<Order> _query(String where) => _db.raw
      .select('SELECT payload FROM orders WHERE $where ORDER BY created_at ASC')
      .map((r) => Order.fromMap(jsonDecode(r['payload'] as String) as Map<String, dynamic>))
      .toList();

  /// Goes through [save] rather than issuing its own UPDATE.
  ///
  /// The indexed columns and the payload blob hold the same facts, so a second
  /// writer is a second chance for them to disagree: an UPDATE that touched only
  /// the columns left `byUuid` returning the pre-sync state forever. One writer,
  /// built from one object, cannot drift.
  void markSynced(String uuid, [int? serverId]) {
    final order = byUuid(uuid);
    if (order == null) return;
    order.state = OrderState.synced;
    if (serverId != null) order.serverId = serverId;
    save(order);
  }

  /// Active kitchen tickets for the KDS board: orders that have been sent to the
  /// kitchen (held or paid) and are not yet served, newest first.
  List<Order> kitchenTickets() => _db.raw
      .select("SELECT payload FROM orders WHERE state IN ('held','paid') "
          'ORDER BY created_at DESC LIMIT 100')
      .map((r) => Order.fromMap(jsonDecode(r['payload'] as String) as Map<String, dynamic>))
      .where((o) => o.kitchenStatus != KitchenStatus.served)
      .toList();

  /// Move a ticket along the kitchen board. Goes through [save] so the indexed
  /// columns and the payload cannot disagree.
  void setKitchenStatus(String uuid, KitchenStatus status) {
    final order = byUuid(uuid);
    if (order == null) return;
    order.kitchenStatus = status;
    save(order);
  }

  /// Discard an order outright. Only safe for a draft or held order that was never
  /// paid; a paid order must be reversed with a refund, never deleted.
  void delete(String uuid) =>
      _db.raw.execute('DELETE FROM orders WHERE uuid = ? AND state IN (?, ?)',
          [uuid, OrderState.draft.name, OrderState.held.name]);

  int get count => _db.raw.select('SELECT COUNT(*) c FROM orders').first['c'] as int;
}
