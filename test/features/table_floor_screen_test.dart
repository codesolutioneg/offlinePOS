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
    bool pickMode = false,
    String? exclude,
  }) =>
      MaterialApp(
        home: TableFloorScreen(
          store: tables,
          occupiedLabels: occupied,
          onOpenTable: onOpenTable ?? (_) {},
          pickMode: pickMode,
          exclude: exclude,
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

  testWidgets('pick mode is the same drawn plan: taps report the table, no edit tools', (t) async {
    final table = tables.add(name: 'T1');
    PosTable? picked;
    await t.pumpWidget(app(pickMode: true, onOpenTable: (tap) => picked = tap));

    // Titled as a chooser, with the occupancy legend, and no floor-edit affordance.
    expect(find.text('Choose a table'), findsOneWidget);
    expect(find.byKey(const Key('toggle-edit')), findsNothing);
    expect(find.byKey(const Key('pick-other')), findsOneWidget);

    await t.tap(find.byKey(Key('table-tile-${table.id}')));
    await t.pump();
    expect(picked?.name, 'T1');
  });

  testWidgets('pick mode hides the excluded table so a bill cannot move onto itself', (t) async {
    tables.add(name: 'T1');
    final t2 = tables.add(name: 'T2');
    await t.pumpWidget(app(pickMode: true, exclude: 'T1'));

    expect(find.text('T1'), findsNothing);
    expect(find.byKey(Key('table-tile-${t2.id}')), findsOneWidget);
  });

  testWidgets('pick mode Other reports a free-text table not on the floor', (t) async {
    tables.add(name: 'T1');
    String? picked;
    await t.pumpWidget(app(pickMode: true, onOpenTable: (tap) => picked = tap.name));

    await t.tap(find.byKey(const Key('pick-other')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('other-table-field')), 'Terrace-9');
    await t.tap(find.text('Set'));
    await t.pumpAndSettle();

    expect(picked, 'Terrace-9');
  });

  testWidgets('pick mode Other with an empty value reports it, to clear a table', (t) async {
    tables.add(name: 'T1');
    String? picked;
    var reported = false;
    await t.pumpWidget(app(pickMode: true, onOpenTable: (tap) {
      picked = tap.name;
      reported = true;
    }));

    await t.tap(find.byKey(const Key('pick-other')));
    await t.pumpAndSettle();
    // Leave the field blank and confirm: the set-table flow reads '' as "clear".
    await t.tap(find.text('Set'));
    await t.pumpAndSettle();

    expect(reported, isTrue);
    expect(picked, '');
  });

  testWidgets('pick mode on an empty floor offers Other, not a floor-edit trap', (t) async {
    await t.pumpWidget(app(pickMode: true));

    // No "Set up the floor" button (it would flip edit mode on with no way out
    // while picking); the Other action is still there to name a table.
    expect(find.byKey(const Key('empty-edit')), findsNothing);
    expect(find.byKey(const Key('pick-other')), findsOneWidget);
  });

  testWidgets('an occupied rectangle table lays out without overflowing its tile', (t) async {
    tables.add(name: 'T3', seats: 6, shape: TableShape.rectangle);
    await t.pumpWidget(app(
      occupied: const {'T3'},
    ));
    await t.pumpAndSettle();
    // The short rectangle tile used to overflow by a few pixels once it carried
    // the occupancy line; the content now scales to fit, so no layout exception.
    expect(t.takeException(), isNull);
    expect(find.text('T3'), findsOneWidget);
  });

  testWidgets('the floor home offers takeaway and delivery buttons', (t) async {
    tables.add(name: 'T1');
    var takeaway = false, delivery = false;
    await t.pumpWidget(MaterialApp(
      home: TableFloorScreen(
        store: tables,
        occupiedLabels: const {},
        onOpenTable: (_) {},
        onTakeaway: () => takeaway = true,
        onDelivery: () => delivery = true,
      ),
    ));
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('floor-takeaway')));
    expect(takeaway, isTrue);
    await t.tap(find.byKey(const Key('floor-delivery')));
    expect(delivery, isTrue);
  });

  testWidgets('the pick-mode floor hides the takeaway/delivery buttons', (t) async {
    tables.add(name: 'T1');
    await t.pumpWidget(app(pickMode: true));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('floor-takeaway')), findsNothing);
    expect(find.byKey(const Key('floor-delivery')), findsNothing);
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

  testWidgets('a vertical divider renders as a rotated bar and is still not tappable', (t) async {
    final wall = tables.add(name: 'Wall', seats: 0, shape: TableShape.divider);
    tables.upsert(wall.copyWith(vertical: true, span: 200));
    bool tapped = false;
    await t.pumpWidget(app(onOpenTable: (_) => tapped = true));

    // A vertical wall draws its label rotated, and never gets the tappable key.
    expect(find.byType(RotatedBox), findsOneWidget);
    expect(find.byKey(Key('table-tile-${wall.id}')), findsNothing);
    expect(find.text('Wall'), findsOneWidget);
    expect(tapped, false);
  });

  testWidgets('editing a divider changes its orientation and length, and it persists',
      (t) async {
    final wall = tables.add(name: 'Wall', seats: 0, shape: TableShape.divider);
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('toggle-edit')));
    await t.pumpAndSettle();

    await t.tap(find.byKey(Key('table-edit-${wall.id}')));
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('orient-vertical')));
    await t.pump();
    // Two taps grow the wall from the 140 default by 40 each.
    await t.tap(find.byKey(const Key('divider-longer')));
    await t.pump();
    await t.tap(find.byKey(const Key('divider-longer')));
    await t.pump();
    await t.tap(find.byKey(const Key('table-save')));
    await t.pumpAndSettle();

    final saved = tables.byId(wall.id)!;
    expect(saved.vertical, isTrue);
    expect(saved.span, 220);
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

  testWidgets('deleting a table asks for confirmation and keeps the table on cancel',
      (t) async {
    final table = tables.add(name: 'T1');
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('toggle-edit')));
    await t.pumpAndSettle();

    await t.tap(find.byKey(Key('table-edit-${table.id}')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('table-delete')));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('confirm-delete-table')), findsOneWidget);
    await t.tap(find.widgetWithText(TextButton, 'Cancel'));
    await t.pumpAndSettle();

    expect(tables.byId(table.id), isNotNull);
  });

  testWidgets('confirming a table delete removes it from the floor', (t) async {
    final table = tables.add(name: 'T1');
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('toggle-edit')));
    await t.pumpAndSettle();

    await t.tap(find.byKey(Key('table-edit-${table.id}')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('table-delete')));
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('confirm-delete-table')));
    await t.pumpAndSettle();

    expect(tables.byId(table.id), isNull);
  });

  testWidgets('deleting a section states the table count and only deletes on confirm',
      (t) async {
    tables.add(name: 'T1', section: 'Terrace');
    tables.add(name: 'T2', section: 'Terrace');
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('toggle-edit')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('section-terrace')));
    await t.pumpAndSettle();

    await t.longPress(find.byKey(const Key('section-terrace')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('section-delete')));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('confirm-delete-section')), findsOneWidget);
    expect(find.textContaining('2'), findsWidgets);

    await t.tap(find.byKey(const Key('confirm-delete-section')));
    await t.pumpAndSettle();

    expect(tables.inSection('Terrace'), isEmpty);
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
