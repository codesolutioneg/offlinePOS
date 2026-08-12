import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/table_store.dart';

import 'sqlite_loader.dart';

void main() {
  late Db db;
  late TableStore tables;
  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    tables = TableStore(db);
  });
  tearDown(() => db.close());

  test('a table name is made unique, so recall never hits the wrong bill', () {
    final a = tables.add(name: 'T1');
    final b = tables.add(name: 'T1');
    final c = tables.add(name: 'T1', section: 'Terrace');
    expect(a.name, 'T1');
    expect(b.name, 'T1-2');
    // Uniqueness is across the whole floor, not just the section, because an order
    // is recalled by table name regardless of section.
    expect(c.name, 'T1-3');
    expect(tables.all().map((t) => t.name).toSet().length, 3);
  });

  test('new tables land on their own grid cell instead of stacking at the origin', () {
    final placed = [for (var i = 0; i < 6; i++) tables.add(name: 'X$i')];
    final cells = placed.map((t) => '${t.x},${t.y}').toSet();
    expect(cells.length, 6, reason: 'no two new tables share a cell');
    // First row fills across, then wraps to the next row.
    expect(placed[0].x, 0);
    expect(placed[5].x, 0);
    expect(placed[5].y, 1);
  });

  test('sections list only holds sections that still have a table', () {
    tables.add(name: 'A', section: 'Main');
    final t = tables.add(name: 'B', section: 'Terrace');
    expect(tables.sections().toSet(), {'Main', 'Terrace'});
    tables.remove(t.id);
    expect(tables.sections(), ['Main']);
  });

  test('a table shape defaults to square and round-trips through the store', () {
    final square = tables.add(name: 'S1');
    expect(square.shape, TableShape.square);
    expect(square.isDivider, false);

    final round = tables.add(name: 'R1', shape: TableShape.round);
    expect(round.shape, TableShape.round);
    expect(tables.byId(round.id)!.shape, TableShape.round);

    final rect = tables.add(name: 'X1', shape: TableShape.rectangle);
    expect(tables.byId(rect.id)!.shape, TableShape.rectangle);
  });

  test('a divider is stored with zero seats and never reads as a normal table', () {
    final wall = tables.add(name: 'Wall', seats: 0, shape: TableShape.divider);
    expect(wall.isDivider, true);
    expect(wall.seats, 0);

    final reloaded = tables.byId(wall.id)!;
    expect(reloaded.isDivider, true);
    expect(reloaded.shape, TableShape.divider);
  });

  test('copyWith changes shape without touching the rest of the table', () {
    final t = tables.add(name: 'C1');
    final round = t.copyWith(shape: TableShape.round);
    expect(round.shape, TableShape.round);
    expect(round.name, t.name);
    expect(round.id, t.id);

    tables.upsert(round);
    expect(tables.byId(t.id)!.shape, TableShape.round);
  });

  test('an unrecognised shape value on disk falls back to square rather than crashing', () {
    final t = tables.add(name: 'Legacy');
    // Simulate a row written before the shape column existed getting some other
    // stray value; the mapper must not choke on it.
    db.raw.execute('UPDATE pos_tables SET shape = ? WHERE id = ?', ['bogus', t.id]);
    expect(tables.byId(t.id)!.shape, TableShape.square);
  });
}
