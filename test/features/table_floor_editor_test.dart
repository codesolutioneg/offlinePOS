import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/table_store.dart';
import 'package:offline_pos/domain/order.dart' show OrderType;
import 'package:offline_pos/features/tables/table_floor_screen.dart';

import '../db/sqlite_loader.dart';

/// The floor editor's selection bar: the controls that place a table without a
/// drag. A drop selects the table it placed, the arrows walk it a cell at a
/// time, and duplicate lays out a row of identical tables in a run of taps.
void main() {
  late Db db;
  late TableStore tables;

  setUpAll(useSystemSqlite);
  setUp(() => db = Db.open(':memory:'));
  setUp(() => tables = TableStore(db));
  tearDown(() => db.close());

  Widget app() => MaterialApp(
        home: TableFloorScreen(
          store: tables,
          occupiedLabels: const {},
          onOpenTable: (_, OrderType _) {},
        ),
      );

  Future<void> dragToSelect(WidgetTester t, PosTable table) async {
    final gesture =
        await t.startGesture(t.getCenter(find.byKey(Key('table-edit-${table.id}'))));
    await t.pump(const Duration(milliseconds: 400));
    await gesture.moveBy(const Offset(140, 0));
    await t.pump();
    await gesture.up();
    await t.pumpAndSettle();
  }

  testWidgets('dropping a table selects it and the arrows nudge it by one cell',
      (t) async {
    final table = tables.add(name: 'T1', x: 0, y: 0);
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('toggle-edit')));
    await t.pumpAndSettle();

    await dragToSelect(t, table);
    expect(find.byKey(const Key('floor-selected-bar')), findsOneWidget,
        reason: 'the drop hands the manager the fine controls');
    final afterDrop = tables.byId(table.id)!;

    await t.tap(find.byKey(const Key('nudge-down')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nudge-right')));
    await t.pumpAndSettle();

    final nudged = tables.byId(table.id)!;
    expect(nudged.y, afterDrop.y + 1);
    expect(nudged.x, afterDrop.x + 1);
  });

  testWidgets('a nudge cannot push a table off the floor', (t) async {
    final table = tables.add(name: 'T1', x: 0, y: 0);
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('toggle-edit')));
    await t.pumpAndSettle();
    await dragToSelect(t, table);
    // Walk it back to the origin, then once more past it.
    await t.tap(find.byKey(const Key('nudge-left')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nudge-left')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nudge-up')));
    await t.pumpAndSettle();

    final walked = tables.byId(table.id)!;
    expect(walked.x, 0);
    expect(walked.y, 0);
  });

  testWidgets('duplicate copies the table onto a free cell and selects the copy',
      (t) async {
    final table = tables.add(name: 'T1', seats: 6, x: 0, y: 0);
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('toggle-edit')));
    await t.pumpAndSettle();
    await dragToSelect(t, table);

    await t.tap(find.byKey(const Key('selected-duplicate')));
    await t.pumpAndSettle();

    final all = tables.inSection('Main');
    expect(all.length, 2);
    final original = tables.byId(table.id)!;
    final copy = all.firstWhere((x) => x.id != table.id);
    expect(copy.seats, 6, reason: 'a duplicate keeps what the original seats');
    expect((x: copy.x, y: copy.y), isNot((x: original.x, y: original.y)),
        reason: 'the copy lands on a free cell, never on the original');
  });

  testWidgets('the seat stepper changes seats without opening the dialog',
      (t) async {
    final table = tables.add(name: 'T1', seats: 4, x: 0, y: 0);
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('toggle-edit')));
    await t.pumpAndSettle();
    await dragToSelect(t, table);

    await t.tap(find.byKey(const Key('seats-plus')));
    await t.pumpAndSettle();
    expect(tables.byId(table.id)!.seats, 5);
    await t.tap(find.byKey(const Key('seats-minus')));
    await t.pumpAndSettle();
    expect(tables.byId(table.id)!.seats, 4);
  });

  testWidgets('a new table lands on a free cell, not on top of the last one',
      (t) async {
    tables.add(name: 'T1', x: 0, y: 0);
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('toggle-edit')));
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('add-table')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('table-name')), 'T2');
    await t.tap(find.byKey(const Key('table-save')));
    await t.pumpAndSettle();

    final added = tables.inSection('Main').firstWhere((x) => x.name == 'T2');
    expect((x: added.x, y: added.y), isNot((x: 0.0, y: 0.0)));
    expect(find.byKey(const Key('floor-selected-bar')), findsOneWidget,
        reason: 'the new table arrives selected, arrows ready');
  });

  testWidgets('closing the selection returns the bar to its add actions',
      (t) async {
    final table = tables.add(name: 'T1', x: 0, y: 0);
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('toggle-edit')));
    await t.pumpAndSettle();
    await dragToSelect(t, table);

    await t.tap(find.byKey(const Key('selected-close')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('floor-selected-bar')), findsNothing);
    expect(find.byKey(const Key('add-table')), findsOneWidget);
  });
}
