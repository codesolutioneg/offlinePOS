import '../lan/lan_event.dart';
import 'database.dart';

/// One clock-in (and later clock-out) for a member of staff.
class AttendanceEntry {
  const AttendanceEntry({
    required this.id,
    required this.staffId,
    required this.clockIn,
    this.clockOut,
  });

  final int id;
  final String staffId;
  final DateTime clockIn;
  final DateTime? clockOut;

  bool get isOpen => clockOut == null;

  /// Worked time so far (to now if still open), for the day's timesheet.
  Duration worked(DateTime now) => (clockOut ?? now).difference(clockIn);

  Map<String, dynamic> toMap() => {
        'staff_id': staffId,
        'clock_in': clockIn.toUtc().toIso8601String(),
        'clock_out': clockOut?.toUtc().toIso8601String(),
      };

  factory AttendanceEntry.fromMap(Map<String, dynamic> m) => AttendanceEntry(
        id: 0,
        staffId: '${m['staff_id']}',
        clockIn: DateTime.parse('${m['clock_in']}').toUtc(),
        clockOut: m['clock_out'] == null
            ? null
            : DateTime.parse('${m['clock_out']}').toUtc(),
      );
}

/// Staff attendance on this till: who is clocked in, and the day's timesheet.
///
/// Deliberately separate from the cash-drawer [Shift]: several cashiers can be on
/// the clock at once against a single till, which the single-open-shift drawer
/// model cannot express.
class AttendanceStore {
  AttendanceStore(
    this._db, {
    DateTime Function()? now,
    void Function(LanEventKind kind, String recordUuid, Map<String, dynamic> payload)?
        publish,
  })  : _now = now ?? DateTime.now,
        _publish = publish;

  final Db _db;
  final DateTime Function() _now;
  final void Function(
      LanEventKind kind, String recordUuid, Map<String, dynamic> payload)? _publish;

  /// Stable fabric key for one staff member's open attendance row.
  static String recordKey(String staffId) => 'attendance:$staffId';

  /// The open (not-yet-clocked-out) entry for a staff member, or null.
  AttendanceEntry? openFor(String staffId) {
    final rows = _db.raw.select(
        'SELECT * FROM attendance WHERE staff_id = ? AND clock_out IS NULL '
        'ORDER BY id DESC LIMIT 1',
        [staffId]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  bool isClockedIn(String staffId) => openFor(staffId) != null;

  /// Clock a staff member in. A no-op that returns the existing entry if they are
  /// already on the clock, so a double tap cannot open two.
  AttendanceEntry clockIn(String staffId, {bool announce = true}) {
    final existing = openFor(staffId);
    if (existing != null) return existing;
    final at = _now().toUtc();
    _db.raw.execute(
        'INSERT INTO attendance (staff_id, clock_in) VALUES (?, ?)',
        [staffId, at.toIso8601String()]);
    final entry = openFor(staffId)!;
    if (announce) _announce(entry);
    return entry;
  }

  /// Clock a staff member out. A no-op if they are not on the clock.
  void clockOut(String staffId, {bool announce = true}) {
    final open = openFor(staffId);
    if (open == null) return;
    final at = _now().toUtc();
    _db.raw.execute('UPDATE attendance SET clock_out = ? WHERE id = ?',
        [at.toIso8601String(), open.id]);
    if (announce) {
      _announce(AttendanceEntry(
        id: open.id,
        staffId: open.staffId,
        clockIn: open.clockIn,
        clockOut: at,
      ));
    }
  }

  /// Apply a peer's attendance snapshot without echoing it back on the fabric.
  void applyRemote(Map<String, dynamic> payload) {
    final entry = AttendanceEntry.fromMap(payload);
    final open = openFor(entry.staffId);
    if (entry.clockOut == null) {
      if (open != null) return;
      _db.raw.execute(
          'INSERT INTO attendance (staff_id, clock_in) VALUES (?, ?)',
          [entry.staffId, entry.clockIn.toIso8601String()]);
      return;
    }
    if (open == null) {
      // Closed elsewhere after we never saw the open — store the full span.
      _db.raw.execute(
          'INSERT INTO attendance (staff_id, clock_in, clock_out) VALUES (?, ?, ?)',
          [
            entry.staffId,
            entry.clockIn.toIso8601String(),
            entry.clockOut!.toIso8601String(),
          ]);
      return;
    }
    _db.raw.execute('UPDATE attendance SET clock_out = ? WHERE id = ?',
        [entry.clockOut!.toIso8601String(), open.id]);
  }

  /// Who is on the clock right now, for a join snapshot.
  List<Map<String, dynamic>> exportOpen() =>
      [for (final e in onNow()) e.toMap()];

  /// Replace open attendance with a primary's join snapshot (no LAN echo).
  void applyOpenSnapshot(List<dynamic> rows) {
    for (final e in onNow()) {
      clockOut(e.staffId, announce: false);
    }
    for (final raw in rows) {
      if (raw is! Map) continue;
      applyRemote(raw.cast<String, dynamic>());
    }
  }

  void _announce(AttendanceEntry entry) {
    final publish = _publish;
    if (publish == null) return;
    publish(LanEventKind.attendanceUpsert, recordKey(entry.staffId), entry.toMap());
  }

  /// Everyone currently on the clock.
  List<AttendanceEntry> onNow() => _db.raw
      .select('SELECT * FROM attendance WHERE clock_out IS NULL ORDER BY clock_in')
      .map(_fromRow)
      .toList();

  /// The entries since [since] (default: the last 24h), newest first, for the
  /// attendance/timesheet view.
  List<AttendanceEntry> recent({DateTime? since, int limit = 200}) {
    final from = (since ?? _now().toUtc().subtract(const Duration(hours: 24)))
        .toUtc()
        .toIso8601String();
    return _db.raw
        .select(
            'SELECT * FROM attendance WHERE clock_in >= ? ORDER BY id DESC LIMIT ?',
            [from, limit])
        .map(_fromRow)
        .toList();
  }

  /// The clock-ins that started inside a window, oldest first, for the hours
  /// report. Both ends are optional, so "everything" is a call with neither.
  ///
  /// Windowed on when the shift started, not on overlap: a night that ran past
  /// midnight belongs to the day the person clocked on, which is how a shop reads
  /// its own rota and how the report adds up to what it paid for that shift.
  /// A row still open is included, and counted up to [now] by the caller.
  List<AttendanceEntry> between({DateTime? from, DateTime? to, String? staffId}) {
    final where = <String>[];
    final args = <Object?>[];
    if (from != null) {
      where.add('clock_in >= ?');
      args.add(from.toUtc().toIso8601String());
    }
    if (to != null) {
      where.add('clock_in < ?');
      args.add(to.toUtc().toIso8601String());
    }
    if (staffId != null) {
      where.add('staff_id = ?');
      args.add(staffId);
    }
    final clause = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')} ';
    return _db.raw
        .select('SELECT * FROM attendance ${clause}ORDER BY clock_in', args)
        .map(_fromRow)
        .toList();
  }

  AttendanceEntry _fromRow(Map<String, Object?> r) => AttendanceEntry(
        id: r['id'] as int,
        staffId: r['staff_id'] as String,
        clockIn: DateTime.parse(r['clock_in'] as String),
        clockOut:
            r['clock_out'] == null ? null : DateTime.parse(r['clock_out'] as String),
      );
}
