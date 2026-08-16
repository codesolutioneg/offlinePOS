import '../../domain/identity.dart';
import '../lan/lan_event.dart';
import 'database.dart';

/// How a floor element is drawn: a real shape for a seatable table, or
/// [divider] for a wall/aisle marker that only marks a section split and is
/// never opened for an order.
enum TableShape { square, round, rectangle, divider }

TableShape _shapeFromDb(String? v) {
  for (final s in TableShape.values) {
    if (s.name == v) return s;
  }
  return TableShape.square;
}

/// A table on the shop floor: which section it sits in, how many it seats, and
/// where on the floor it is drawn.
class PosTable {
  const PosTable({
    required this.id,
    required this.name,
    this.section = 'Main',
    this.seats = 4,
    this.x = 0,
    this.y = 0,
    this.sequence = 0,
    this.shape = TableShape.square,
    this.vertical = false,
    this.span = 140,
  });

  final String id;
  final String name;
  final String section;
  final int seats;

  /// Position on the floor, in logical grid units. The editor writes these; the
  /// floor view lays tables out by them, which is what makes it a drawn plan
  /// rather than a plain list.
  final double x;
  final double y;
  final int sequence;
  final TableShape shape;

  /// Divider-only geometry, ignored by seatable tables. [vertical] draws the wall
  /// as a tall bar instead of a wide one; [span] is its long side in logical
  /// pixels, so a manager can enlarge or shrink a wall to fit the aisle.
  final bool vertical;
  final int span;

  /// A divider is a visual wall/aisle marker, not a seatable table: it never
  /// shows as occupied and is never tapped to open an order.
  bool get isDivider => shape == TableShape.divider;

  /// The wire shape for the LAN fabric, so a floor laid out on one device reaches
  /// the others. Column names, not field names, so the payload reads the same as
  /// the row it came from.
  Map<String, dynamic> toMap() => {
        'id': id,
        'section': section,
        'name': name,
        'seats': seats,
        'pos_x': x,
        'pos_y': y,
        'sequence': sequence,
        'shape': shape.name,
        'vertical': vertical,
        'span': span,
      };

  /// Throws if the payload is not a table. An unreadable event is refused by the
  /// applier rather than written as a half-built table on the floor.
  factory PosTable.fromMap(Map<String, dynamic> m) => PosTable(
        id: m['id'] as String,
        name: m['name'] as String,
        section: (m['section'] as String?) ?? 'Main',
        seats: (m['seats'] as num?)?.toInt() ?? 4,
        x: (m['pos_x'] as num?)?.toDouble() ?? 0,
        y: (m['pos_y'] as num?)?.toDouble() ?? 0,
        sequence: (m['sequence'] as num?)?.toInt() ?? 0,
        shape: _shapeFromDb(m['shape'] as String?),
        vertical: m['vertical'] == true,
        span: (m['span'] as num?)?.toInt() ?? 140,
      );

  PosTable copyWith({
    String? name,
    String? section,
    int? seats,
    double? x,
    double? y,
    int? sequence,
    TableShape? shape,
    bool? vertical,
    int? span,
  }) =>
      PosTable(
        id: id,
        name: name ?? this.name,
        section: section ?? this.section,
        seats: seats ?? this.seats,
        x: x ?? this.x,
        y: y ?? this.y,
        sequence: sequence ?? this.sequence,
        shape: shape ?? this.shape,
        vertical: vertical ?? this.vertical,
        span: span ?? this.span,
      );
}

/// The floor plan on disk. Reads answer with no network so the floor is usable
/// during an outage exactly like the catalogue.
///
/// The plan is laid out on one device but every till needs it, so each change is
/// announced to the LAN fabric when one is wired. With no fabric this class writes
/// exactly what it always wrote.
class TableStore {
  TableStore(this._db, {LanPublish? publish}) : _publish = publish;

  final Db _db;

  final LanPublish? _publish;

  List<PosTable> all() => _db.raw
      .select('SELECT * FROM pos_tables ORDER BY section, sequence, name')
      .map(_map)
      .toList();

  List<PosTable> inSection(String section) => _db.raw
      .select('SELECT * FROM pos_tables WHERE section = ? ORDER BY sequence, name',
          [section])
      .map(_map)
      .toList();

  /// The distinct sections, in first-seen order, so the floor can tab between them.
  List<String> sections() {
    final rows = _db.raw.select(
        'SELECT section, MIN(sequence) s FROM pos_tables GROUP BY section ORDER BY s, section');
    return rows.map((r) => r['section'] as String).toList();
  }

  PosTable? byId(String id) {
    final rows = _db.raw.select('SELECT * FROM pos_tables WHERE id = ?', [id]);
    return rows.isEmpty ? null : _map(rows.first);
  }

  /// Which part of the floor the table called [name] sits in, or null when the shop
  /// has no floor plan or rang the sale against a name it never laid out. Answered
  /// by name because that is all an order keeps of the table it was sat at, and
  /// names are unique across the floor (see [uniqueName]). A scan of a floor plan,
  /// which is tens of rows on disk, so the receipt path can ask on its way to the
  /// printer without a sale ever waiting on it.
  String? sectionFor(String name) {
    final rows = _db.raw
        .select('SELECT section FROM pos_tables WHERE name = ? LIMIT 1', [name]);
    return rows.isEmpty ? null : rows.first['section'] as String?;
  }

  bool get isEmpty =>
      (_db.raw.select('SELECT COUNT(*) c FROM pos_tables').first['c'] as int) == 0;

  /// Add a table, returning it with its generated id.
  ///
  /// The name is made unique across the whole floor, because an order is recalled
  /// by its table name: two tables sharing a name would recall the wrong bill. When
  /// no position is given the table is dropped on the next free grid cell rather
  /// than stacked at the origin.
  PosTable add({
    required String name,
    String section = 'Main',
    int seats = 4,
    double? x,
    double? y,
    TableShape shape = TableShape.square,
  }) {
    final seq = _nextSequence(section);
    final table = PosTable(
      id: Uuid.v4(),
      name: uniqueName(name),
      section: section,
      seats: seats,
      x: x ?? (seq % 5).toDouble(),
      y: y ?? (seq ~/ 5).toDouble(),
      sequence: seq,
      shape: shape,
    );
    upsert(table);
    return table;
  }

  /// A name not already used by another table, suffixing -2, -3 on a collision.
  String uniqueName(String desired) {
    final taken = all().map((t) => t.name).toSet();
    if (!taken.contains(desired)) return desired;
    var n = 2;
    while (taken.contains('$desired-$n')) {
      n++;
    }
    return '$desired-$n';
  }

  /// [announce] is false only when the change arrived from another till, so the
  /// floor plan is not bounced back to the device that drew it.
  void upsert(PosTable t, {bool announce = true}) {
    final publish = _publish;
    _commit(
      () => _db.raw.execute(
        'INSERT INTO pos_tables (id, section, name, seats, pos_x, pos_y, sequence, shape, vertical, span) '
        'VALUES (?,?,?,?,?,?,?,?,?,?) '
        'ON CONFLICT(id) DO UPDATE SET section=excluded.section, name=excluded.name, '
        'seats=excluded.seats, pos_x=excluded.pos_x, pos_y=excluded.pos_y, '
        'sequence=excluded.sequence, shape=excluded.shape, vertical=excluded.vertical, '
        'span=excluded.span',
        [t.id, t.section, t.name, t.seats, t.x, t.y, t.sequence, t.shape.name,
          t.vertical ? 1 : 0, t.span],
      ),
      announce && publish != null
          ? () => publish(LanEventKind.tableUpsert, t.id, t.toMap())
          : null,
    );
  }

  void remove(String id, {bool announce = true}) {
    final publish = _publish;
    _commit(
      () => _db.raw.execute('DELETE FROM pos_tables WHERE id = ?', [id]),
      announce && publish != null
          ? () => publish(LanEventKind.tableUpsert, id, {'id': id, 'deleted': true})
          : null,
    );
  }

  /// Rename a whole section (moves every table in it).
  ///
  /// A table at a time rather than one bulk UPDATE, so each move carries its own
  /// event and the other tills end up with the same floor rather than a section
  /// that only exists here.
  void renameSection(String from, String to) {
    final target = to.trim();
    for (final t in inSection(from)) {
      upsert(t.copyWith(section: target));
    }
  }

  /// Delete a section and all its tables.
  void deleteSection(String section) {
    for (final t in inSection(section)) {
      remove(t.id);
    }
  }

  /// One writer, optionally with the fabric event in the same transaction so a
  /// table cannot be announced as moved unless it really moved. A failed announce
  /// still commits the change: the floor plan in front of the manager is what they
  /// just drew, and refusing their edit because a peer table misbehaved would be
  /// the wrong way round.
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

  int _nextSequence(String section) =>
      (_db.raw.select('SELECT COALESCE(MAX(sequence), -1) + 1 n FROM pos_tables '
              'WHERE section = ?', [section]).first['n'] as int);

  PosTable _map(Map<String, Object?> r) => PosTable(
        id: r['id'] as String,
        name: r['name'] as String,
        section: r['section'] as String,
        seats: r['seats'] as int,
        x: (r['pos_x'] as num).toDouble(),
        y: (r['pos_y'] as num).toDouble(),
        sequence: r['sequence'] as int,
        shape: _shapeFromDb(r['shape'] as String?),
        vertical: (r['vertical'] as int? ?? 0) != 0,
        span: r['span'] as int? ?? 140,
      );
}
