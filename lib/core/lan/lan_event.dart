/// What one till tells the others it just did.
///
/// The first wave carries exactly three things, because those are the ones a shop
/// notices are missing the moment it runs a second device: a parked or paid order,
/// where a ticket is in the kitchen, and the floor plan a manager laid out. Nothing
/// here invents a new record type, so every event applies through a store that
/// already exists and every screen keeps reading the same local database.
enum LanEventKind {
  /// A held or paid order, the whole payload. Drafts are deliberately absent: an
  /// order still being rung is not shared state, and replicating every tap would
  /// put a network write behind the fastest path in the app.
  orderUpsert('order.upsert'),

  /// One ticket moving along the kitchen board. Sent on its own rather than as an
  /// order upsert so a kitchen screen can advance a ticket it does not own without
  /// claiming authorship of somebody else's sale.
  kitchenStatus('kitchen.status'),

  /// A floor element added, moved, resized or deleted. Table occupancy itself is
  /// not a kind: it is derived from the parked orders, which already replicate, so
  /// a second source of truth for "table 5 is busy" cannot disagree with the bill
  /// sitting on it.
  tableUpsert('table.upsert'),

  /// One product marked sold out or put back on. Its own kind rather than part of
  /// an order, because running out is a fact about the shop and not about a sale:
  /// the till that hears it last must end up refusing the same item as the one that
  /// heard the kitchen shout.
  productAvailability('product.availability'),

  /// A parked tab changing hands, announced by the till that gave it up. Only the
  /// owner ever sends it, and it sends it as part of letting go, so a tab still has
  /// exactly one owner at every instant: the single-writer rule survives the
  /// handover instead of being suspended for it.
  orderClaim('order.claim'),

  /// A table booked ahead, changed or called off. Shared for the same reason the
  /// floor plan is: a booking taken at the counter has to reach the handheld the
  /// waiter is holding, or two people promise one table.
  reservationUpsert('reservation.upsert');

  const LanEventKind(this.wire);

  /// The name on the wire. Fixed apart from the enum so renaming a Dart constant
  /// cannot silently break a till running the previous build.
  final String wire;

  static LanEventKind? fromWire(String wire) {
    for (final kind in LanEventKind.values) {
      if (kind.wire == wire) return kind;
    }
    return null;
  }
}

/// Announces a committed local change to the fabric, called from inside the
/// store's own write transaction so the record and the event land together.
///
/// A store holds null for this on a till with the fabric off, which is what keeps
/// a one-till shop on exactly the code path it ran before the fabric existed.
typedef LanPublish = void Function(
    LanEventKind kind, String recordUuid, Map<String, dynamic> payload);

/// One entry in a till's append-only log, as it travels the LAN.
///
/// [seq] is the originating till's own counter, which is what a peer stores as a
/// cursor: a rejoining device asks for everything after the last seq it applied,
/// so a partition heals with one request and no full resend.
class LanEvent {
  const LanEvent({
    required this.kind,
    required this.originDeviceId,
    required this.seq,
    required this.recordUuid,
    required this.payload,
    required this.at,
  });

  final LanEventKind kind;

  /// The till that made the change. Also the deterministic tiebreak when two
  /// tills stamp the same instant; see LanApplier.
  final String originDeviceId;

  final int seq;

  /// The uuid of the record this describes: an order uuid, or a table id. The
  /// idempotency key, exactly like the outbox: applying the same event twice has
  /// to land the same row, never a second one.
  final String recordUuid;

  final Map<String, dynamic> payload;

  /// When the change was made on the originating till, in UTC.
  final DateTime at;

  Map<String, dynamic> toMap() => {
        'kind': kind.wire,
        'origin': originDeviceId,
        'seq': seq,
        'uuid': recordUuid,
        'payload': payload,
        'at': at.toIso8601String(),
      };

  /// Throws [FormatException] on anything it cannot read, including an unknown
  /// kind. The caller treats that as a refused event and logs it: a till must not
  /// half-apply something it does not understand.
  factory LanEvent.fromMap(Map<String, dynamic> m) {
    final kind = LanEventKind.fromWire('${m['kind']}');
    if (kind == null) throw FormatException('unknown event kind ${m['kind']}');
    final payload = m['payload'];
    if (payload is! Map) throw FormatException('event ${m['uuid']} has no payload');
    final seq = m['seq'];
    final origin = m['origin'];
    final uuid = m['uuid'];
    if (seq is! int || origin is! String || uuid is! String) {
      throw const FormatException('event is missing origin, seq or uuid');
    }
    return LanEvent(
      kind: kind,
      originDeviceId: origin,
      seq: seq,
      recordUuid: uuid,
      payload: payload.cast<String, dynamic>(),
      at: DateTime.parse('${m['at']}').toUtc(),
    );
  }
}
