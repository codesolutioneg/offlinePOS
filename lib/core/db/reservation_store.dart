import '../../domain/identity.dart';
import '../lan/lan_event.dart';
import 'database.dart';

/// Where a booking is up to.
///
/// [cancelled] and [noShow] are kept rather than deleted because they are the two
/// facts a shop actually wants at the end of a week: how many tables were given
/// away and how many nobody sat at.
enum ReservationState { booked, seated, cancelled, noShow }

ReservationState _stateFromDb(String? v) {
  for (final s in ReservationState.values) {
    if (s.name == v) return s;
  }
  return ReservationState.booked;
}

/// A table booked ahead: who is coming, when, for how many, and where they are
/// being put.
class Reservation {
  Reservation({
    String? uuid,
    required this.name,
    required this.at,
    this.tableLabel,
    this.phone,
    this.covers = 2,
    this.state = ReservationState.booked,
    this.note,
  }) : uuid = uuid ?? Uuid.v4();

  final String uuid;

  /// The table the guests are being put on, or null for a booking taken before
  /// anyone decided where to seat it.
  final String? tableLabel;
  final String name;
  final String? phone;

  /// When they are expected, in UTC like every other timestamp on the till. The
  /// floor renders it as the wall clock a waiter reads.
  final DateTime at;
  final int covers;
  final ReservationState state;
  final String? note;

  /// Whether this booking is still coming: what the floor colours a table for, and
  /// what the day's list counts.
  bool get isOpen => state == ReservationState.booked;

  /// How long until the guests are due. Negative once they are late.
  Duration dueIn(DateTime now) => at.difference(now.toUtc());

  Map<String, dynamic> toMap() => {
        'uuid': uuid,
        'table_label': tableLabel,
        'name': name,
        'phone': phone,
        'at': at.toIso8601String(),
        'covers': covers,
        'state': state.name,
        'note': note,
      };

  /// Throws if the payload is not a booking. An unreadable event is refused by the
  /// applier rather than written as half a reservation on the floor.
  factory Reservation.fromMap(Map<String, dynamic> m) => Reservation(
        uuid: m['uuid'] as String,
        tableLabel: m['table_label'] as String?,
        name: m['name'] as String,
        phone: m['phone'] as String?,
        at: DateTime.parse(m['at'] as String).toUtc(),
        covers: (m['covers'] as num?)?.toInt() ?? 2,
        state: _stateFromDb(m['state'] as String?),
        note: m['note'] as String?,
      );

  Reservation copyWith({
    String? tableLabel,
    bool clearTable = false,
    String? name,
    String? phone,
    DateTime? at,
    int? covers,
    ReservationState? state,
    String? note,
  }) =>
      Reservation(
        uuid: uuid,
        tableLabel: clearTable ? null : (tableLabel ?? this.tableLabel),
        name: name ?? this.name,
        phone: phone ?? this.phone,
        at: at ?? this.at,
        covers: covers ?? this.covers,
        state: state ?? this.state,
        note: note ?? this.note,
      );
}

/// The book, on disk.
///
/// Local like everything else, so a shop takes a booking over the phone with the
/// line down and the floor still knows the table is spoken for. Announced to the
/// other devices when a fabric is wired, because a booking taken at the counter has
/// to reach the waiter's handheld.
class ReservationStore {
  ReservationStore(this._db, {LanPublish? publish}) : _publish = publish;

  final Db _db;
  final LanPublish? _publish;

  /// Bookings between two instants, soonest first. The day's list.
  List<Reservation> between(DateTime from, DateTime to) => _db.raw
      .select('SELECT * FROM reservations WHERE at >= ? AND at < ? ORDER BY at',
          [from.toUtc().toIso8601String(), to.toUtc().toIso8601String()])
      .map(_map)
      .toList();

  List<Reservation> all() =>
      _db.raw.select('SELECT * FROM reservations ORDER BY at').map(_map).toList();

  Reservation? byUuid(String uuid) {
    final rows =
        _db.raw.select('SELECT * FROM reservations WHERE uuid = ?', [uuid]);
    return rows.isEmpty ? null : _map(rows.first);
  }

  /// The bookings still to arrive within [within] of [now], by table.
  ///
  /// What the floor puts on a tile: a table with guests due in twenty minutes is
  /// not free, whatever its colour says, and a waiter seating a walk-in on it is
  /// the mistake this exists to stop. A booking with no table yet is nobody's tile,
  /// so it is left out. The soonest booking wins a tile that has two.
  Map<String, Reservation> dueByTable(DateTime now,
      {Duration within = const Duration(hours: 1)}) {
    final due = <String, Reservation>{};
    // From an hour behind, so a table whose guests are late still reads as spoken
    // for rather than quietly freeing itself the moment they are overdue.
    for (final r in between(now.subtract(const Duration(hours: 1)), now.add(within))) {
      final table = r.tableLabel;
      if (table == null || !r.isOpen) continue;
      due.putIfAbsent(table, () => r);
    }
    return due;
  }

  /// Write a booking, announcing it once it is committed. [announce] is false only
  /// when it arrived from another device, so a booking is never bounced back to the
  /// till that took it.
  void save(Reservation r, {bool announce = true}) {
    final publish = _publish;
    _commit(
      () => _db.raw.execute(
        'INSERT INTO reservations (uuid, table_label, name, phone, at, covers, '
        'state, note, updated_at) VALUES (?,?,?,?,?,?,?,?,?) '
        'ON CONFLICT(uuid) DO UPDATE SET table_label=excluded.table_label, '
        'name=excluded.name, phone=excluded.phone, at=excluded.at, '
        'covers=excluded.covers, state=excluded.state, note=excluded.note, '
        'updated_at=excluded.updated_at',
        [
          r.uuid,
          r.tableLabel,
          r.name,
          r.phone,
          r.at.toUtc().toIso8601String(),
          r.covers,
          r.state.name,
          r.note,
          DateTime.now().toUtc().toIso8601String(),
        ],
      ),
      announce && publish != null
          ? () => publish(LanEventKind.reservationUpsert, r.uuid, r.toMap())
          : null,
    );
  }

  /// Move a booking along (seated, cancelled, did not turn up). A no-op on a
  /// booking that is not here, so a stale tap cannot invent one.
  void setState(String uuid, ReservationState state) {
    final r = byUuid(uuid);
    if (r == null) return;
    save(r.copyWith(state: state));
  }

  void remove(String uuid, {bool announce = true}) {
    final publish = _publish;
    _commit(
      () => _db.raw.execute('DELETE FROM reservations WHERE uuid = ?', [uuid]),
      announce && publish != null
          ? () => publish(
              LanEventKind.reservationUpsert, uuid, {'uuid': uuid, 'deleted': true})
          : null,
    );
  }

  /// One writer, optionally with the fabric event in the same transaction. A failed
  /// announce still commits: the booking in front of whoever took the phone call is
  /// what they just wrote down, and losing it because a peer table misbehaved would
  /// be the wrong way round.
  void _commit(void Function() write, void Function()? announce) {
    if (announce == null) {
      write();
      return;
    }
    _db.raw.execute('BEGIN');
    try {
      write();
      announce();
      _db.raw.execute('COMMIT');
    } catch (_) {
      _db.raw.execute('ROLLBACK');
      write();
    }
  }

  Reservation _map(Map<String, Object?> r) => Reservation(
        uuid: r['uuid'] as String,
        tableLabel: r['table_label'] as String?,
        name: r['name'] as String,
        phone: r['phone'] as String?,
        at: DateTime.parse(r['at'] as String).toUtc(),
        covers: r['covers'] as int? ?? 2,
        state: _stateFromDb(r['state'] as String?),
        note: r['note'] as String?,
      );
}
