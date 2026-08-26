import '../lan/lan_event.dart';
import 'database.dart';

/// One table given to one waiter for the service, with the trail of who gave it to
/// them and when.
///
/// Deliberately not part of [PosTable]: the floor plan is a manager's drawing that
/// changes a few times a year, and this changes at the start of every shift. Riding
/// on the same row would mean a table dragged an inch on one till could clobber an
/// assignment made on another, since the fabric resolves a conflict per record.
class TableAssignment {
  const TableAssignment({
    required this.tableId,
    required this.cashierId,
    required this.assignedAt,
    required this.assignedBy,
  });

  final String tableId;

  /// The waiter the table belongs to. Never empty: a table with nobody on it has no
  /// row at all rather than a row naming nobody.
  final String cashierId;

  final DateTime assignedAt;

  /// Who handed it over, which is a manager or the till itself. Kept because "who
  /// gave Ahmed the terrace" is the question asked the morning after a bill went
  /// missing, and the audit trail alone cannot answer it once a row is overwritten.
  final String assignedBy;

  /// The wire shape for the LAN fabric, so a room shared out on the manager's till
  /// reaches the handhelds. Column names, not field names, so the payload reads the
  /// same as the row it came from.
  Map<String, dynamic> toMap() => {
        'table_id': tableId,
        'cashier_id': cashierId,
        'assigned_at': assignedAt.toIso8601String(),
        'assigned_by': assignedBy,
      };

  /// Throws if the payload is not an assignment, so the applier refuses it rather
  /// than writing a table over to nobody.
  factory TableAssignment.fromMap(Map<String, dynamic> m) => TableAssignment(
        tableId: m['table_id'] as String,
        cashierId: m['cashier_id'] as String,
        assignedAt: DateTime.parse(m['assigned_at'] as String),
        assignedBy: (m['assigned_by'] as String?) ?? 'system',
      );
}

/// Who works which table, on disk.
///
/// Reads answer with no network, like the floor plan itself: a waiter walking into
/// a dead spot in the building still knows which tables are theirs. Every change is
/// announced to the LAN fabric when one is wired, because the manager shares the
/// room out on one device and the waiters read it on others; with no fabric this
/// class writes exactly what it writes now.
class TableAssignmentStore {
  TableAssignmentStore(this._db, {LanPublish? publish, DateTime Function()? now})
      : _publish = publish,
        _now = now ?? DateTime.now;

  final Db _db;
  final LanPublish? _publish;
  final DateTime Function() _now;

  /// The name this record travels the fabric under.
  ///
  /// Prefixed, and NOT the bare table id, because the fabric's last-write-wins clock
  /// is keyed on the record alone: an assignment sharing the table's key would make a
  /// table dragged an inch and a table handed to a waiter fight over one clock, and
  /// whichever was written second would roll the other one back.
  static String recordKey(String tableId) => 'assign:$tableId';

  /// Table id -> waiter, which is the shape the floor reads: it draws every tile in
  /// one pass and asks this once rather than per table.
  Map<String, String> byTable() {
    final rows = _db.raw.select('SELECT table_id, cashier_id FROM table_assignments');
    return {
      for (final r in rows) r['table_id'] as String: r['cashier_id'] as String,
    };
  }

  /// The waiter this table belongs to, or null when it belongs to nobody and is
  /// therefore open to anyone.
  String? cashierFor(String tableId) {
    final rows = _db.raw.select(
        'SELECT cashier_id FROM table_assignments WHERE table_id = ?', [tableId]);
    return rows.isEmpty ? null : rows.first['cashier_id'] as String?;
  }

  /// The table ids one waiter is holding.
  List<String> tablesFor(String cashierId) => _db.raw
      .select('SELECT table_id FROM table_assignments WHERE cashier_id = ?',
          [cashierId])
      .map((r) => r['table_id'] as String)
      .toList();

  bool get isEmpty =>
      (_db.raw.select('SELECT COUNT(*) c FROM table_assignments').first['c'] as int) ==
      0;

  /// Give [tableId] to [cashierId], replacing whoever had it.
  ///
  /// Returns the row written, so a caller can audit exactly what landed. A blank
  /// cashier is a clear, not an assignment to nobody: the two are the same intent
  /// from a picker with a "nobody" option on it, and only one of them may reach the
  /// table.
  TableAssignment? assign(String tableId, String cashierId,
      {required String by, bool announce = true}) {
    if (cashierId.trim().isEmpty) {
      clear(tableId, announce: announce);
      return null;
    }
    final row = TableAssignment(
      tableId: tableId,
      cashierId: cashierId,
      assignedAt: _now(),
      assignedBy: by,
    );
    apply(row, announce: announce);
    return row;
  }

  /// Write an assignment as given. [announce] is false only when the change arrived
  /// from another till, so a room shared out over there is not bounced back to it.
  void apply(TableAssignment a, {bool announce = true}) {
    final publish = _publish;
    _commit(
      () => _db.raw.execute(
        'INSERT INTO table_assignments (table_id, cashier_id, assigned_at, assigned_by) '
        'VALUES (?,?,?,?) '
        'ON CONFLICT(table_id) DO UPDATE SET cashier_id=excluded.cashier_id, '
        'assigned_at=excluded.assigned_at, assigned_by=excluded.assigned_by',
        [a.tableId, a.cashierId, a.assignedAt.toIso8601String(), a.assignedBy],
      ),
      announce && publish != null
          ? () => publish(
              LanEventKind.tableAssignment, recordKey(a.tableId), a.toMap())
          : null,
    );
  }

  /// Hand a table back to nobody, which opens it to everyone again.
  void clear(String tableId, {bool announce = true}) {
    final publish = _publish;
    _commit(
      () => _db.raw
          .execute('DELETE FROM table_assignments WHERE table_id = ?', [tableId]),
      announce && publish != null
          ? () => publish(LanEventKind.tableAssignment, recordKey(tableId),
              {'table_id': tableId, 'deleted': true})
          : null,
    );
  }

  /// Hand the whole room back, which is what the end of a shift means: the next one
  /// is shared out fresh, and a table left assigned to whoever went home is a table
  /// the next waiter cannot open.
  ///
  /// Returns how many were cleared, for the trail. One row at a time rather than one
  /// bulk DELETE, so each clear carries its own event and the other tills end up with
  /// the same empty room instead of one that is only empty here.
  int clearAll({bool announce = true}) {
    final ids = _db.raw
        .select('SELECT table_id FROM table_assignments')
        .map((r) => r['table_id'] as String)
        .toList();
    for (final id in ids) {
      clear(id, announce: announce);
    }
    return ids.length;
  }

  /// One writer, optionally with the fabric event in the same transaction so a table
  /// cannot be announced as handed over unless it really was. A failed announce still
  /// commits: the room in front of the manager is the one they just shared out, and
  /// refusing that because a peer till misbehaved would be the wrong way round.
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
}
