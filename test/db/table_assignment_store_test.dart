import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/table_assignment_store.dart';
import 'package:offline_pos/core/db/table_store.dart';

import 'sqlite_loader.dart';

/// Who works which table, on disk.
///
/// What matters here is what a service actually does to these rows: one waiter per
/// table, a section moved from one waiter to another mid-shift, a table handed back,
/// and the room emptied at the Z. A table taken off the floor must take its
/// assignment with it, or a redrawn room slowly fills with rows nobody can see.
void main() {
  setUpAll(useSystemSqlite);

  late Db db;
  late TableStore tables;
  late TableAssignmentStore assignments;

  setUp(() {
    db = Db.open(':memory:');
    tables = TableStore(db);
    assignments = TableAssignmentStore(db);
  });
  tearDown(() => db.close());

  test('a table starts belonging to nobody', () {
    final t = tables.add(name: 'T1');
    expect(assignments.isEmpty, isTrue);
    expect(assignments.cashierFor(t.id), isNull);
    expect(assignments.byTable(), isEmpty);
  });

  test('assigning names the waiter, and who handed it over', () {
    final t = tables.add(name: 'T1');
    final row = assignments.assign(t.id, 'ana', by: 'boss');

    expect(row?.cashierId, 'ana');
    expect(row?.assignedBy, 'boss');
    expect(assignments.cashierFor(t.id), 'ana');
    expect(assignments.byTable(), {t.id: 'ana'});
    expect(assignments.isEmpty, isFalse);
  });

  test('a second assignment replaces the first: one waiter per table', () {
    final t = tables.add(name: 'T1');
    assignments.assign(t.id, 'ana', by: 'boss');
    assignments.assign(t.id, 'omar', by: 'boss');

    expect(assignments.cashierFor(t.id), 'omar');
    expect(assignments.tablesFor('ana'), isEmpty);
    expect(assignments.tablesFor('omar'), [t.id]);
  });

  test('a waiter holds every table given to them', () {
    final a = tables.add(name: 'T1');
    final b = tables.add(name: 'T2');
    final c = tables.add(name: 'T3');
    assignments.assign(a.id, 'ana', by: 'boss');
    assignments.assign(b.id, 'ana', by: 'boss');
    assignments.assign(c.id, 'omar', by: 'boss');

    expect(assignments.tablesFor('ana')..sort(), [a.id, b.id]..sort());
    expect(assignments.tablesFor('omar'), [c.id]);
  });

  test('clearing hands the table back to everybody', () {
    final t = tables.add(name: 'T1');
    assignments.assign(t.id, 'ana', by: 'boss');
    assignments.clear(t.id);

    expect(assignments.cashierFor(t.id), isNull);
    expect(assignments.isEmpty, isTrue);
  });

  test('assigning to nobody is a clear, not a table owned by an empty name', () {
    final t = tables.add(name: 'T1');
    assignments.assign(t.id, 'ana', by: 'boss');

    expect(assignments.assign(t.id, '', by: 'boss'), isNull);
    expect(assignments.cashierFor(t.id), isNull);
  });

  test('the Z hands the whole room back and says how much of it there was', () {
    final a = tables.add(name: 'T1');
    final b = tables.add(name: 'T2');
    assignments.assign(a.id, 'ana', by: 'boss');
    assignments.assign(b.id, 'omar', by: 'boss');

    expect(assignments.clearAll(), 2);
    expect(assignments.isEmpty, isTrue);
    // And a second Z over an empty room is not an error.
    expect(assignments.clearAll(), 0);
  });

  test('a table taken off the floor takes its assignment with it', () {
    final t = tables.add(name: 'T1');
    assignments.assign(t.id, 'ana', by: 'boss');

    tables.remove(t.id);

    expect(assignments.byTable(), isEmpty);
    expect(assignments.tablesFor('ana'), isEmpty);
  });

  test('deleting a section takes the assignments of every table in it', () {
    final a = tables.add(name: 'T1', section: 'Terrace');
    final b = tables.add(name: 'T2', section: 'Terrace');
    final inside = tables.add(name: 'T3', section: 'Main');
    assignments.assign(a.id, 'ana', by: 'boss');
    assignments.assign(b.id, 'ana', by: 'boss');
    assignments.assign(inside.id, 'omar', by: 'boss');

    tables.deleteSection('Terrace');

    expect(assignments.byTable(), {inside.id: 'omar'});
  });

  test('a waiter off the roster keeps their tables until a manager moves them', () {
    // Deliberate: no foreign key on the cashier. Somebody going home mid-shift must
    // not silently open their section to everybody.
    final t = tables.add(name: 'T1');
    assignments.assign(t.id, 'gone-home', by: 'boss');

    expect(assignments.cashierFor(t.id), 'gone-home');
  });

  test('an assignment survives the table being renamed or moved', () {
    final t = tables.add(name: 'T1');
    assignments.assign(t.id, 'ana', by: 'boss');

    // Keyed on the id, not the name, so the floor can be redrawn around a live
    // service without handing anybody's section away.
    tables.upsert(t.copyWith(name: 'Terrace 1', x: 3, y: 4, section: 'Terrace'));

    expect(assignments.cashierFor(t.id), 'ana');
  });
}
