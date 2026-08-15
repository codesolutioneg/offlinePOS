import 'dart:convert';

import '../../domain/order.dart';
import '../lan/lan_cart_board.dart';
import '../lan/lan_event.dart';
import 'database.dart';

/// Takes a sale's queued server push back out of the outbox, returning false when
/// it can no longer be withdrawn because it is already on the wire or acknowledged.
///
/// Passed in rather than reached for, so this store keeps knowing about orders and
/// nothing about the queue they are delivered through.
typedef WithdrawPush = bool Function(String uuid);

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
    bool Function()? publishesCart,
    void Function(String uuid, Object error)? onAnnounceFailed,
  })  : _publish = publish,
        _publishesCart = publishesCart,
        _onAnnounceFailed = onAnnounceFailed;

  final Db _db;

  /// The id of the till this store belongs to, or null on a single-till build and
  /// in the tests that predate the fabric, where every row is by definition local.
  final String? ownDeviceId;

  /// Announces a committed change to the LAN fabric. Null with the fabric off, and
  /// then this class behaves exactly as it did before the fabric existed: no
  /// transaction, no event, no socket.
  final LanPublish? _publish;

  /// Whether this till feeds a customer-facing display. Read at the moment of the
  /// write rather than held, so switching the display off stops the writes at once.
  /// Null (and false) is the ordinary till, which then behaves exactly as it did
  /// before displays existed: a draft announces nothing at all.
  final bool Function()? _publishesCart;

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
    if (!announce || publish == null) {
      _write(order, null);
      return;
    }
    final shares = _isShared(order);
    final cart = _cartEventFor(order);
    if (!shares && cart == null) {
      _write(order, null);
      return;
    }
    _write(order, () {
      if (shares) publish(LanEventKind.orderUpsert, order.uuid, order.toMap());
      if (cart != null) publish(LanEventKind.cartDisplay, ownDeviceId ?? '', cart);
    });
  }

  /// The counter as a customer-facing display should show it, or null when this
  /// till is not feeding one.
  ///
  /// A draft is the cart being rung; anything committed means the counter is done
  /// with it, so the display is cleared rather than left showing a bill somebody
  /// has already paid to the next customer in the queue.
  Map<String, dynamic>? _cartEventFor(Order order) {
    if (ownDeviceId == null || !(_publishesCart?.call() ?? false)) return null;
    if (order.deviceId != ownDeviceId) return null;
    final live = order.state == OrderState.draft;
    return LanCartSnapshot(
      deviceId: ownDeviceId!,
      lines: [
        if (live)
          for (final l in order.lines)
            LanCartLine(name: l.name, quantity: l.quantity, total: l.total),
      ],
      total: live ? order.total : 0,
      at: DateTime.now().toUtc(),
    ).toMap();
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

  /// The device and cashier columns follow the payload on an update, because a tab
  /// can change hands both ways: to another till, and to another cashier on this
  /// one. Leaving them behind would file the order under whoever used to have it
  /// while the bill on it says otherwise, and the reads that decide money are
  /// scoped by exactly those columns.
  void _insert(Order order) {
    _db.raw.execute(
      '''
      INSERT INTO orders (uuid, device_id, cashier_id, created_at, state, server_id, total, payload)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(uuid) DO UPDATE SET
        device_id = excluded.device_id, cashier_id = excluded.cashier_id,
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

  /// Put a paid sale back on the counter to be corrected, and say whether it went.
  /// Rang wrong, or a customer added something a moment after checkout: a daily
  /// flow that otherwise costs a refund and a re-ring.
  ///
  /// A SYNCED order can never be reopened, and that is the rule this method exists
  /// to hold. The server treats a repeat of a uuid as a duplicate acknowledgement
  /// of the sale it already booked, never as an update, so an amended sale pushed
  /// under its old uuid would leave the books showing the pre-edit version with
  /// nothing anywhere saying so. Once the server has the sale the only honest
  /// answer is a refund and a re-ring. It is enforced here rather than by hiding a
  /// button because the row on disk is the one thing every caller is bound by.
  ///
  /// [withdrawPush] pulls the sale out of the outbox inside the same transaction as
  /// the state change, so the queue and the order can never disagree about which
  /// version is owed. It refusing is a refusal to reopen: a push that is already on
  /// the wire will be booked whatever happens here, and editing behind it would
  /// hand the customer a receipt the books will never match.
  ///
  /// The tenders are cleared with the state. The sale is going back to being
  /// un-tendered and will be taken again in full, and leaving them on would make
  /// the payment sheet read the order as part-paid and append a second set of
  /// tenders to the first.
  ///
  /// Nothing is announced, for the same reason [recall] announces nothing: a draft
  /// is the till's own working state. The other tills keep showing the sale as it
  /// was until it is tendered again, which re-announces the corrected version.
  ///
  /// One window stays open and cannot be closed from this side: a push whose HTTP
  /// call reached the server but whose acknowledgement was lost leaves the order
  /// paid with its row still queued, and reopening there loses the correction to
  /// the server's duplicate handling. The next batch push resolves it, because the
  /// server answers the repeat with a duplicate status and the order is marked
  /// synced from that.
  bool reopen(String uuid, {required WithdrawPush withdrawPush}) {
    final order = byUuid(uuid);
    if (order == null) return false;
    // Only a tendered sale is reopened: a draft or a held tab is editable already,
    // and synced is the state this must never move.
    if (order.state != OrderState.paid) return false;
    // Another till's sale is booked by that till, exactly as its tabs are settled
    // there, so it is not this one's to rewrite.
    if (ownDeviceId != null && order.deviceId != ownDeviceId) return false;
    // A refund reverses a sale that stands. Editing one back into the cart would
    // turn a credit into a fresh order made of negative lines.
    if (order.isRefund) return false;
    _db.raw.execute('BEGIN');
    try {
      if (!withdrawPush(uuid)) {
        _db.raw.execute('ROLLBACK');
        return false;
      }
      order.state = OrderState.draft;
      order.payments = [];
      order.cashReceived = null;
      // Rides on the order so the corrected receipt is marked whenever it prints,
      // including a reprint days later and after a restart mid-correction.
      order.amended = true;
      _insert(order);
      _db.raw.execute('COMMIT');
      return true;
    } catch (_) {
      _db.raw.execute('ROLLBACK');
      rethrow;
    }
  }

  // ── a tab changing hands ─────────────────────────────────────────

  /// Give a parked tab to another till, and say what was handed over.
  ///
  /// Null is a refusal, and the refusals are the whole point of the method. Only a
  /// HELD order can move: a draft is being rung by a cashier standing at a counter,
  /// and a paid one is money this till is going to book. Only the till that owns it
  /// can give it away, so two devices cannot both hand out the same tab, and the
  /// giving up and the announcing happen in one transaction, so there is no instant
  /// where nobody owns it or both do.
  ///
  /// The order is rebuilt rather than edited because its device is what identifies
  /// the till that will settle it: making that field writable would let anything
  /// anywhere quietly reassign a sale.
  Order? handOver(String uuid, String toDeviceId) {
    final order = byUuid(uuid);
    if (order == null) return null;
    if (order.state != OrderState.held) return null;
    if (order.deviceId == toDeviceId) return order;
    if (ownDeviceId != null && order.deviceId != ownDeviceId) return null;
    final moved = _withDevice(order, toDeviceId);
    final publish = _publish;
    _write(
      moved,
      publish == null
          ? null
          : () => publish(LanEventKind.orderClaim, uuid,
              {'to': toDeviceId, 'from': order.deviceId}),
    );
    return moved;
  }

  /// Record a handover that happened elsewhere. Announces nothing: the till that
  /// gave the tab up is the one that said so, and a second announcement would be a
  /// second claim of authorship over one move.
  ///
  /// A tab that is already paid is left alone whatever the event says. Money that
  /// has been taken belongs to the till that took it, and no later ownership change
  /// may move it somewhere it would be booked again.
  bool applyHandOver(String uuid, String toDeviceId) {
    final order = byUuid(uuid);
    if (order == null) return false;
    if (order.state != OrderState.held) return false;
    if (order.deviceId == toDeviceId) return true;
    _write(_withDevice(order, toDeviceId), null);
    return true;
  }

  /// The same order under a different till. Goes through the map so nothing about
  /// the bill can be lost in the copy.
  static Order _withDevice(Order order, String deviceId) =>
      Order.fromMap({...order.toMap(), 'device_id': deviceId});

  /// Move a parked tab to another cashier on this till, and say whether it moved.
  ///
  /// What a manager does when somebody goes home mid-service: the tables they
  /// opened have to answer to whoever is on the floor now, or they cannot be picked
  /// up under table security and they land on the wrong cashier's flash. Only a
  /// held tab moves; a paid sale keeps the cashier who rang it, because that name
  /// is the only record of who took the money.
  bool reassignCashier(String uuid, String toCashierId) {
    final order = byUuid(uuid);
    if (order == null || order.state != OrderState.held) return false;
    if (order.cashierId == toCashierId) return true;
    save(Order.fromMap({...order.toMap(), 'cashier_id': toCashierId}));
    return true;
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
