import '../../domain/identity.dart';
import 'database.dart';

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

  PosTable copyWith({
    String? name,
    String? section,
    int? seats,
    double? x,
    double? y,
    int? sequence,
  }) =>
      PosTable(
        id: id,
        name: name ?? this.name,
        section: section ?? this.section,
        seats: seats ?? this.seats,
        x: x ?? this.x,
        y: y ?? this.y,
        sequence: sequence ?? this.sequence,
      );
}

/// The floor plan on disk. Reads answer with no network so the floor is usable
/// during an outage exactly like the catalogue.
class TableStore {
  TableStore(this._db);

  final Db _db;

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

  bool get isEmpty =>
      (_db.raw.select('SELECT COUNT(*) c FROM pos_tables').first['c'] as int) == 0;

  /// Add a table, returning it with its generated id.
  PosTable add({
    required String name,
    String section = 'Main',
    int seats = 4,
    double x = 0,
    double y = 0,
  }) {
    final table = PosTable(
      id: Uuid.v4(),
      name: name,
      section: section,
      seats: seats,
      x: x,
      y: y,
      sequence: _nextSequence(section),
    );
    upsert(table);
    return table;
  }

  void upsert(PosTable t) => _db.raw.execute(
        'INSERT INTO pos_tables (id, section, name, seats, pos_x, pos_y, sequence) '
        'VALUES (?,?,?,?,?,?,?) '
        'ON CONFLICT(id) DO UPDATE SET section=excluded.section, name=excluded.name, '
        'seats=excluded.seats, pos_x=excluded.pos_x, pos_y=excluded.pos_y, '
        'sequence=excluded.sequence',
        [t.id, t.section, t.name, t.seats, t.x, t.y, t.sequence],
      );

  void remove(String id) =>
      _db.raw.execute('DELETE FROM pos_tables WHERE id = ?', [id]);

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
      );
}
