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
}
