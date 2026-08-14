import 'dart:convert';

import '../../domain/order.dart';
import '../lan/lan_event.dart';
import 'database.dart';

/// Orders on disk. Every mutation is written immediately, not at payment, so a
/// half-rung sale survives the app being killed.
///
/// With the LAN fabric on, this table also holds orders replicated from the other
/// tills in the shop, which is what lets one device show the whole floor and a
/// kitchen screen show every ticket. The split is deliberate and load-bearing:
/// reads that decide money ([drafts], [held], [awaitingSync], [recent]) are scoped
/// to this till, and reads that only serve food ([kitchenTickets], [heldAnywhere])
/// see the whole shop. That is what makes it impossible for a sale rung on another
/// till to be recalled, reported or pushed to Odoo from here.
class OrderStore {
  OrderStore(
    this._db, {
    this.ownDeviceId,
    LanPublish? publish,
    void Function(String uuid, Object error)? onAnnounceFailed,
  })  : _publish = publish,
        _onAnnounceFailed = onAnnounceFailed;

  final Db _db;

  /// The id of the till this store belongs to, or null on a single-till build and
  /// in the tests that predate the fabric, where every row is by definition local.
  final String? ownDeviceId;

  /// Announces a committed change to the LAN fabric. Null with the fabric off, and
  /// then this class behaves exactly as it did before the fabric existed: no
  /// transaction, no event, no socket.
  final LanPublish? _publish;

  /// Told when a change was committed but could not be announced. The sale wins,
  /// so this is how a shop finds out its tills stopped replicating.
  final void Function(String uuid, Object error)? _onAnnounceFailed;

  /// Persist an order, announcing it to the other tills once it is committed.
  ///
  /// [announce] is false only when the order arrived from another till: the fabric
  /// applies it through this same single writer, and re-announcing it would have
  /// two devices claiming the same sale and echoing it back and forth.
  void save(Order order, {bool announce = true}) {
    final publish = _publish;
    final shares = announce && publish != null && _isShared(order);
    _write(
      order,
      shares
          ? () => publish(LanEventKind.orderUpsert, order.uuid, order.toMap())
          : null,
    );
  }

  /// Whether this order is shared state.
  ///
  /// A draft is not: it is being rung right now on the till in front of the
  /// cashier, it changes on every tap, and no other device has any use for it.
  /// Anything committed (held, paid, synced) is what a second till and a kitchen
  /// screen need. Only the till that created the order ever announces it.
  bool _isShared(Order order) =>
      order.state != OrderState.draft &&
      (ownDeviceId == null || order.deviceId == ownDeviceId);

  /// The single writer for a row, optionally with its fabric event in the same
  /// transaction so an event cannot describe a record that was never committed.
  ///
  /// If the event cannot be written the order is committed on its own. A sale
  /// outranks replication every time: losing money because a peer bookkeeping table
  /// misbehaved would be a far worse bug than two tills disagreeing about a tab.
  void _write(Order order, void Function()? announce) {
    if (announce == null) {
      _insert(order);
      return;
    }
    _db.raw.execute('BEGIN');
    try {
      _insert(order);
      announce();
      _db.raw.execute('COMMIT');
    } catch (e) {
      _db.raw.execute('ROLLBACK');
      _insert(order);
      _onAnnounceFailed?.call(order.uuid, e);
    }
  }

  void _insert(Order order) {
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
  /// cashier gets their work back after a crash or a closed window.
  List<Order> drafts() => _mine("state = 'draft'");

  /// Orders parked on a table or tab, waiting to be recalled and paid. The open
  /// tabs a cashier switches between during a dine-in service.
  ///
  /// This till's own only. A tab is settled on the till it was opened on, because
  /// that till is the one that will book it, and a bill paid twice in two places is
  /// not a trade-off worth making for the convenience.
  List<Order> held() => _mine("state = 'held'");

  /// Every parked order in the shop, this till's and the ones replicated from the
  /// others. Read by the floor plan so a table busy on another till reads as busy
  /// here, which is the whole reason the fabric exists.
  List<Order> heldAnywhere() => _query("state = 'held'");

  /// Parked orders belonging to another till. Empty on a single-till shop and with
  /// the fabric off.
  List<Order> heldElsewhere() => ownDeviceId == null
      ? const []
      : _query("state = 'held' AND device_id <> ?", [ownDeviceId]);

  /// Paid but not yet confirmed by the server.
  ///
  /// Scoped to this till, and that scoping is what keeps the books straight: this
  /// is the list the sync reconcile sweeps into the outbox, so a sale replicated
  /// from another till must never appear in it or the shop would book it twice.
  List<Order> awaitingSync() => _mine("state = 'paid'");

  /// Completed sales, newest first, for the history / reprint browser and the
  /// reports. Includes both paid-not-yet-synced and synced, so a sale shows up the
  /// instant it is taken, not only after the server confirms. This till's own: a
  /// second till's takings are not this till's to report on.
  List<Order> recent({int limit = 50}) {
    final own = ownDeviceId;
    return _db.raw
        .select(
            "SELECT payload FROM orders WHERE state IN ('paid','synced')"
            "${own == null ? '' : ' AND device_id = ?'} "
            'ORDER BY created_at DESC LIMIT ?',
            [?own, limit])
        .map((r) =>
            Order.fromMap(jsonDecode(r['payload'] as String) as Map<String, dynamic>))
        .toList();
  }

  /// [_query] restricted to orders this till rang.
  List<Order> _mine(String where) => ownDeviceId == null
      ? _query(where)
      : _query('$where AND device_id = ?', [ownDeviceId]);

  List<Order> _query(String where, [List<Object?> args = const []]) => _db.raw
      .select('SELECT payload FROM orders WHERE $where ORDER BY created_at ASC', args)
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
  ///
  /// Shop-wide on purpose. A kitchen screen is a device of its own that rings up
  /// nothing, so every ticket it shows arrived over the fabric; scoping this to one
  /// till would leave a dedicated board permanently blank.
  List<Order> kitchenTickets() => _db.raw
      .select("SELECT payload FROM orders WHERE state IN ('held','paid') "
          'ORDER BY created_at DESC LIMIT 100')
      .map((r) => Order.fromMap(jsonDecode(r['payload'] as String) as Map<String, dynamic>))
      .where((o) => o.kitchenStatus != KitchenStatus.served)
      .toList();

  /// Move a ticket along the kitchen board. Goes through the same single writer as
  /// [save] so the indexed columns and the payload cannot disagree.
  ///
  /// The change is announced as a status event rather than as a whole order, which
  /// is what lets a kitchen screen bump a ticket it does not own: it says "this
  /// ticket is ready", not "this is my sale".
  void setKitchenStatus(String uuid, KitchenStatus status, {bool announce = true}) {
    final order = byUuid(uuid);
    if (order == null) return;
    order.kitchenStatus = status;
    final publish = _publish;
    _write(
      order,
      announce && publish != null
          ? () => publish(
              LanEventKind.kitchenStatus, uuid, {'status': status.name})
          : null,
    );
  }

  /// Discard an order outright. Only safe for a draft or held order that was never
  /// paid; a paid order must be reversed with a refund, never deleted.
  ///
  /// A discarded tab is announced like any other change to it. Without that, a
  /// table cancelled on one till would sit on every other till's floor plan as
  /// permanently occupied, and a waiter would stop trusting the colours.
  void delete(String uuid, {bool announce = true}) {
    final publish = _publish;
    final order = announce && publish != null ? byUuid(uuid) : null;
    void remove() => _db.raw.execute(
        'DELETE FROM orders WHERE uuid = ? AND state IN (?, ?)',
        [uuid, OrderState.draft.name, OrderState.held.name]);
    if (order == null || publish == null || !_isShared(order)) {
      remove();
      return;
    }
    _db.raw.execute('BEGIN');
    try {
      remove();
      publish(LanEventKind.orderUpsert, uuid,
          {...order.toMap(), 'deleted': true});
      _db.raw.execute('COMMIT');
    } catch (e) {
      _db.raw.execute('ROLLBACK');
      remove();
      _onAnnounceFailed?.call(uuid, e);
    }
  }

  int get count => _db.raw.select('SELECT COUNT(*) c FROM orders').first['c'] as int;
}
