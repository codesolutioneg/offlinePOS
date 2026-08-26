import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/table_store.dart';
import 'package:offline_pos/domain/order.dart' show OrderType;
import 'package:offline_pos/features/tables/table_floor_screen.dart';

import '../db/sqlite_loader.dart';

/// The floor, once the manager has shared it out.
///
/// The rule being proven is the one the shop asked for: a waiter sees the whole
/// room and opens only their own part of it, and a manager can override that on the
/// spot. What must NOT happen is a waiter losing sight of a table, or a shop that
/// assigns nothing behaving any differently from before.
void main() {
  late Db db;
  late TableStore tables;

  setUpAll(useSystemSqlite);
  setUp(() => db = Db.open(':memory:'));
  setUp(() => tables = TableStore(db));
  tearDown(() => db.close());

  const staff = [
    (id: 'ana', name: 'Ana', active: true),
    (id: 'omar', name: 'Omar', active: true),
  ];

  Widget app({
    Map<String, String> assignments = const {},
    String? me = 'ana',
    bool mayOpenAnyTable = false,
    Future<bool> Function()? authorizeForeignTable,
    void Function(PosTable, String?)? onAssign,
    Future<bool> Function()? authorizeAssign,
    bool assignHint = false,
    bool shiftOpen = true,
    void Function(PosTable, OrderType)? onOpenTable,
  }) =>
      MaterialApp(
        home: TableFloorScreen(
          store: tables,
          occupiedLabels: const {},
          onOpenTable: onOpenTable ?? (_, _) {},
          assignments: assignments,
          staff: staff,
          myCashierId: me,
          mayOpenAnyTable: mayOpenAnyTable,
          authorizeForeignTable: authorizeForeignTable,
          onAssign: onAssign,
          authorizeAssign: authorizeAssign,
          assignHint: assignHint,
          shiftOpen: () => shiftOpen,
        ),
      );

  testWidgets('with nothing assigned the floor is exactly what it was', (t) async {
    final table = tables.add(name: 'T1');
    PosTable? opened;
    await t.pumpWidget(app(onOpenTable: (tap, _) => opened = tap));

    expect(find.byKey(Key('table-waiter-${table.id}')), findsNothing);
    expect(find.byKey(Key('table-locked-${table.id}')), findsNothing);

    await t.tap(find.byKey(Key('table-tile-${table.id}')));
    await t.pumpAndSettle();
    expect(opened?.id, table.id);
  });

  testWidgets('a waiter opens their own table and sees their name on it', (t) async {
    final table = tables.add(name: 'T1');
    PosTable? opened;
    await t.pumpWidget(app(
      assignments: {table.id: 'ana'},
      onOpenTable: (tap, _) => opened = tap,
    ));

    expect(find.byKey(Key('table-waiter-${table.id}')), findsOneWidget);
    expect(find.text('Ana'), findsOneWidget);
    expect(find.byKey(Key('table-locked-${table.id}')), findsNothing);

    await t.tap(find.byKey(Key('table-tile-${table.id}')));
    await t.pumpAndSettle();
    expect(opened?.id, table.id);
  });

  testWidgets('a colleague\'s table is visible, named and locked', (t) async {
    final mine = tables.add(name: 'T1');
    final theirs = tables.add(name: 'T2');
    await t.pumpWidget(app(assignments: {mine.id: 'ana', theirs.id: 'omar'}));

    // Seen, not hidden: a waiter has to be able to read the whole room.
    expect(find.text('T2'), findsOneWidget);
    expect(find.text('Omar'), findsOneWidget);
    expect(find.byKey(Key('table-locked-${theirs.id}')), findsOneWidget);
    expect(find.byKey(Key('table-locked-${mine.id}')), findsNothing);
  });

  testWidgets('tapping a colleague\'s table does not open it', (t) async {
    final theirs = tables.add(name: 'T2');
    var opened = 0;
    await t.pumpWidget(app(
      assignments: {theirs.id: 'omar'},
      authorizeForeignTable: () async => false,
      onOpenTable: (_, _) => opened++,
    ));

    await t.tap(find.byKey(Key('table-tile-${theirs.id}')));
    await t.pumpAndSettle();

    // Refused by name, so the waiter knows who to go to rather than guessing.
    expect(find.byKey(const Key('foreign-table-dialog')), findsOneWidget);
    expect(find.text('Table T2 · Omar'), findsOneWidget);

    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(opened, 0);
  });

  testWidgets('a manager PIN opens a colleague\'s table', (t) async {
    final theirs = tables.add(name: 'T2');
    var asked = 0;
    PosTable? opened;
    await t.pumpWidget(app(
      assignments: {theirs.id: 'omar'},
      authorizeForeignTable: () async {
        asked++;
        return true;
      },
      onOpenTable: (tap, _) => opened = tap,
    ));

    await t.tap(find.byKey(Key('table-tile-${theirs.id}')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('foreign-table-approve')));
    await t.pumpAndSettle();

    expect(asked, 1);
    expect(opened?.id, theirs.id);
  });

  testWidgets('a refused approval leaves the table shut', (t) async {
    final theirs = tables.add(name: 'T2');
    var opened = 0;
    await t.pumpWidget(app(
      assignments: {theirs.id: 'omar'},
      authorizeForeignTable: () async => false,
      onOpenTable: (_, _) => opened++,
    ));

    await t.tap(find.byKey(Key('table-tile-${theirs.id}')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('foreign-table-approve')));
    await t.pumpAndSettle();

    expect(opened, 0);
  });

  testWidgets('a manager sees every name and no locks, and opens anything', (t) async {
    final theirs = tables.add(name: 'T2');
    PosTable? opened;
    await t.pumpWidget(app(
      assignments: {theirs.id: 'omar'},
      me: 'boss',
      mayOpenAnyTable: true,
      onOpenTable: (tap, _) => opened = tap,
    ));

    expect(find.text('Omar'), findsOneWidget);
    expect(find.byKey(Key('table-locked-${theirs.id}')), findsNothing);

    await t.tap(find.byKey(Key('table-tile-${theirs.id}')));
    await t.pumpAndSettle();
    // Straight through: a manager is not asked to approve themselves.
    expect(find.byKey(const Key('foreign-table-dialog')), findsNothing);
    expect(opened?.id, theirs.id);
  });

  testWidgets('the shift gate outranks the assignment: no drawer, no table', (t) async {
    final mine = tables.add(name: 'T1');
    var opened = 0;
    await t.pumpWidget(app(
      assignments: {mine.id: 'ana'},
      shiftOpen: false,
      onOpenTable: (_, _) => opened++,
    ));

    await t.tap(find.byKey(Key('table-tile-${mine.id}')));
    await t.pumpAndSettle();

    expect(opened, 0);
    expect(find.byKey(const Key('floor-no-shift')), findsOneWidget);
  });

  testWidgets('assign mode hands a table to a waiter', (t) async {
    final table = tables.add(name: 'T1');
    final given = <(String, String?)>[];
    await t.pumpWidget(app(
      onAssign: (tapped, cashier) => given.add((tapped.name, cashier)),
      authorizeAssign: () async => true,
    ));

    await t.tap(find.byKey(const Key('toggle-assign')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('floor-assigning')), findsOneWidget);

    await t.tap(find.byKey(Key('table-assign-${table.id}')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('assign-to-omar')));
    await t.pumpAndSettle();

    expect(given, [('T1', 'omar')]);
  });

  testWidgets('assign mode can hand a table back to nobody', (t) async {
    final table = tables.add(name: 'T1');
    final given = <(String, String?)>[];
    await t.pumpWidget(app(
      assignments: {table.id: 'omar'},
      onAssign: (tapped, cashier) => given.add((tapped.name, cashier)),
      authorizeAssign: () async => true,
    ));

    await t.tap(find.byKey(const Key('toggle-assign')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('table-assign-${table.id}')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('assign-to-nobody')));
    await t.pumpAndSettle();

    expect(given, [('T1', null)]);
  });

  testWidgets('a refused approval never opens assign mode', (t) async {
    final table = tables.add(name: 'T1');
    var given = 0;
    await t.pumpWidget(app(
      onAssign: (_, _) => given++,
      authorizeAssign: () async => false,
    ));

    await t.tap(find.byKey(const Key('toggle-assign')));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('floor-assigning')), findsNothing);
    expect(find.byKey(Key('table-assign-${table.id}')), findsNothing);
    expect(given, 0);
  });

  testWidgets('the whole section goes to one waiter in one pick', (t) async {
    tables.add(name: 'T1');
    tables.add(name: 'T2');
    tables.add(name: 'Wall', shape: TableShape.divider);
    final given = <(String, String?)>[];
    await t.pumpWidget(app(
      onAssign: (tapped, cashier) => given.add((tapped.name, cashier)),
      authorizeAssign: () async => true,
    ));

    await t.tap(find.byKey(const Key('toggle-assign')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('assign-section')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('assign-to-ana')));
    await t.pumpAndSettle();

    // The wall seats nobody, so it is not handed to anybody either.
    expect(given, [('T1', 'ana'), ('T2', 'ana')]);
  });

  testWidgets('the start-of-service nudge shows until the room is shared out',
      (t) async {
    final table = tables.add(name: 'T1');
    await t.pumpWidget(app(
      onAssign: (_, _) {},
      authorizeAssign: () async => true,
      assignHint: true,
    ));
    expect(find.byKey(const Key('floor-assign-hint')), findsOneWidget);

    // Straight into assign mode from the strip.
    await t.tap(find.byKey(const Key('floor-assign-now')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('floor-assigning')), findsOneWidget);
    expect(find.byKey(const Key('floor-assign-hint')), findsNothing);

    // And gone once something is assigned.
    await t.pumpWidget(app(
      assignments: {table.id: 'ana'},
      onAssign: (_, _) {},
      authorizeAssign: () async => true,
      assignHint: true,
    ));
    expect(find.byKey(const Key('floor-assign-hint')), findsNothing);
  });

  testWidgets('no nudge with no drawer open: the shift strip is what matters',
      (t) async {
    tables.add(name: 'T1');
    await t.pumpWidget(app(
      onAssign: (_, _) {},
      authorizeAssign: () async => true,
      assignHint: true,
      shiftOpen: false,
    ));

    expect(find.byKey(const Key('floor-assign-hint')), findsNothing);
    expect(find.byKey(const Key('floor-no-shift')), findsOneWidget);
  });

  testWidgets('a waiter who may not assign is not offered the nudge', (t) async {
    tables.add(name: 'T1');
    await t.pumpWidget(app(onAssign: (_, _) {}, authorizeAssign: () async => true));

    expect(find.byKey(const Key('floor-assign-hint')), findsNothing);
    // The action itself stays, so a manager can still be called over to a handheld.
    expect(find.byKey(const Key('toggle-assign')), findsOneWidget);
  });

  testWidgets('typing a colleague\'s table name into Other does not get round it',
      (t) async {
    final theirs = tables.add(name: 'T2');
    var picked = 0;
    await t.pumpWidget(MaterialApp(
      home: TableFloorScreen(
        store: tables,
        occupiedLabels: const {},
        pickMode: true,
        assignments: {theirs.id: 'omar'},
        staff: staff,
        myCashierId: 'ana',
        mayOpenAnyTable: false,
        authorizeForeignTable: () async => false,
        onOpenTable: (_, _) => picked++,
      ),
    ));

    await t.tap(find.byKey(const Key('pick-other')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('other-table-field')), 'T2');
    await t.tap(find.text('Set'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('foreign-table-approve')));
    await t.pumpAndSettle();

    expect(picked, 0);
  });

  testWidgets('a table not on the floor is still free to name', (t) async {
    final theirs = tables.add(name: 'T2');
    String? named;
    await t.pumpWidget(MaterialApp(
      home: TableFloorScreen(
        store: tables,
        occupiedLabels: const {},
        pickMode: true,
        assignments: {theirs.id: 'omar'},
        staff: staff,
        myCashierId: 'ana',
        mayOpenAnyTable: false,
        authorizeForeignTable: () async => false,
        onOpenTable: (tapped, _) => named = tapped.name,
      ),
    ));

    await t.tap(find.byKey(const Key('pick-other')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('other-table-field')), 'Terrace-9');
    await t.tap(find.text('Set'));
    await t.pumpAndSettle();

    expect(named, 'Terrace-9');
  });
}
