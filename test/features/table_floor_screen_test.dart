import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/table_store.dart';
import 'package:offline_pos/features/tables/table_floor_screen.dart';

import '../db/sqlite_loader.dart';

void main() {
  late Db db;
  late TableStore tables;

  setUpAll(useSystemSqlite);
  setUp(() => db = Db.open(':memory:'));
  setUp(() => tables = TableStore(db));
  tearDown(() => db.close());

  Widget app({
    Set<String> occupied = const {},
    void Function(PosTable)? onOpenTable,
  }) =>
      MaterialApp(
        home: TableFloorScreen(
          store: tables,
          occupiedLabels: occupied,
          onOpenTable: onOpenTable ?? (_) {},
        ),
      );

  testWidgets('a table renders on the floor and tapping it opens it', (t) async {
    final table = tables.add(name: 'T1');
    PosTable? opened;
    await t.pumpWidget(app(onOpenTable: (tap) => opened = tap));

    expect(find.byKey(Key('table-tile-${table.id}')), findsOneWidget);
    expect(find.text('T1'), findsOneWidget);

    await t.tap(find.byKey(Key('table-tile-${table.id}')));
    await t.pump();

    expect(opened?.id, table.id);
  });

  testWidgets('a divider is drawn but never tapped to open an order', (t) async {
    final wall = tables.add(name: 'Wall', seats: 0, shape: TableShape.divider);
    bool tapped = false;
    await t.pumpWidget(app(onOpenTable: (_) => tapped = true));

    // Only a seatable table gets the tappable service-view key.
    expect(find.byKey(Key('table-tile-${wall.id}')), findsNothing);
    expect(find.text('Wall'), findsOneWidget);
    expect(tapped, false);
  });

  testWidgets('edit mode offers both an add-table and an add-divider action', (t) async {
    tables.add(name: 'T1');
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('toggle-edit')));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('add-table')), findsOneWidget);
    expect(find.byKey(const Key('add-divider')), findsOneWidget);
  });

  testWidgets('adding a table lets the manager pick its shape, and it persists', (t) async {
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('toggle-edit')));
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('add-table')));
    await t.pumpAndSettle();

    await t.enterText(find.byKey(const Key('table-name')), 'Patio 1');
    await t.tap(find.byKey(const Key('shape-round')));
    await t.pump();
    await t.tap(find.byKey(const Key('table-save')));
    await t.pumpAndSettle();

    final saved = tables.all().singleWhere((x) => x.name == 'Patio 1');
    expect(saved.shape, TableShape.round);
  });

  testWidgets('the add-divider action drops a divider row with zero seats', (t) async {
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('toggle-edit')));
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('add-divider')));
    await t.pumpAndSettle();

    final wall = tables.all().singleWhere((x) => x.isDivider);
    expect(wall.seats, 0);
    expect(wall.shape, TableShape.divider);
  });

  testWidgets('long-press dragging a table in edit mode snaps its position to the grid',
      (t) async {
    final table = tables.add(name: 'T1', x: 0, y: 0);
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('toggle-edit')));
    await t.pumpAndSettle();

    final tileFinder = find.byKey(Key('table-edit-${table.id}'));
    expect(tileFinder, findsOneWidget);

    final gesture = await t.startGesture(t.getCenter(tileFinder));
    // Past the LongPressDraggable's start delay before moving, so the gesture
    // arena resolves to a drag rather than a tap.
    await t.pump(const Duration(milliseconds: 400));
    await gesture.moveBy(const Offset(110, 0));
    await t.pump();
    await gesture.up();
    await t.pumpAndSettle();

    final moved = tables.byId(table.id)!;
    expect(moved.x, 1);
    expect(moved.y, 0);
  });
}
