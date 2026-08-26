import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/db/table_store.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/domain/table_preorder.dart';
import 'package:offline_pos/features/settings/table_preorder_screen.dart';

import '../db/sqlite_loader.dart';

/// The screen a manager sets a cover charge on.
///
/// The list is what the till reads at every seating, so what is proven here is that
/// the screen writes exactly what the store then resolves: a room's list, one table's
/// override, and the table put back on the room's list again.
void main() {
  late Db db;
  late SettingsStore settings;
  late TableStore tables;
  late CatalogueStore catalogue;
  late PosTable five;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    settings = SettingsStore(db);
    tables = TableStore(db);
    catalogue = CatalogueStore(db);
    five = tables.add(name: '5');
    tables.add(name: '6');
    catalogue.replaceAll(
      categories: const [Category(id: 1, name: 'Drinks')],
      products: const [
        Product(id: 11, name: 'Cover charge', price: 20, categoryId: 1),
        Product(id: 12, name: 'Water', price: 15, categoryId: 1),
      ],
      groups: const [],
      productGroupIds: const {},
      refreshedAt: DateTime.utc(2026, 1, 1),
    );
  });
  tearDown(() => db.close());

  Widget app() => MaterialApp(
        home: TablePreorderScreen(
            settings: settings, tables: tables, catalogue: catalogue),
      );

  Future<void> addLine(WidgetTester t, Key addButton, int productId,
      {bool perGuest = false}) async {
    await t.tap(find.byKey(addButton));
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('preorder-product-$productId')));
    await t.pumpAndSettle();
    if (perGuest) {
      await t.tap(find.byKey(const Key('preorder-per-guest')));
      await t.pumpAndSettle();
    }
    await t.tap(find.byKey(const Key('preorder-line-save')));
    await t.pumpAndSettle();
  }

  testWidgets('a room opens with nothing until somebody says otherwise', (t) async {
    await t.pumpWidget(app());

    expect(find.text('Opens with nothing'), findsOneWidget);
    expect(find.text('Same as the section'), findsNWidgets(2));
  });

  testWidgets('a cover charge is added to the whole room, per guest', (t) async {
    await t.pumpWidget(app());

    await addLine(t, const Key('preorder-section-add'), 11, perGuest: true);

    final lines = settings.sectionPreorders('Main');
    expect(lines, hasLength(1));
    expect(lines.single.productId, 11);
    expect(lines.single.perGuest, isTrue);
    // Named on screen, and said to be per guest.
    expect(find.text('Cover charge'), findsOneWidget);
    expect(find.textContaining('per guest'), findsOneWidget);
  });

  testWidgets('a quantity of two is stored as two', (t) async {
    await t.pumpWidget(app());

    await t.tap(find.byKey(const Key('preorder-section-add')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('preorder-product-12')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('preorder-qty-up')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('preorder-line-save')));
    await t.pumpAndSettle();

    expect(settings.sectionPreorders('Main').single.quantity, 2);
  });

  testWidgets('the quantity never goes below one', (t) async {
    await t.pumpWidget(app());

    await t.tap(find.byKey(const Key('preorder-section-add')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('preorder-product-12')));
    await t.pumpAndSettle();
    for (var i = 0; i < 3; i++) {
      await t.tap(find.byKey(const Key('preorder-qty-down')));
      await t.pumpAndSettle();
    }
    await t.tap(find.byKey(const Key('preorder-line-save')));
    await t.pumpAndSettle();

    expect(settings.sectionPreorders('Main').single.quantity, 1);
  });

  testWidgets('a line comes off again', (t) async {
    settings.setSectionPreorders('Main', const [TablePreorder(productId: 11)]);
    await t.pumpWidget(app());

    await t.tap(find.descendant(
        of: find.byKey(const Key('preorder-section-line-0')),
        matching: find.byIcon(Icons.remove_circle_outline)));
    await t.pumpAndSettle();

    expect(settings.sectionPreorders('Main'), isEmpty);
  });

  testWidgets('one table can be given its own list instead of the room\'s', (t) async {
    settings.setSectionPreorders('Main', const [TablePreorder(productId: 11)]);
    await t.pumpWidget(app());

    await addLine(t, Key('preorder-add-${five.id}'), 12);

    expect(settings.tablePreorders(five.id)!.single.productId, 12);
    // The room is untouched, and so is the other table in it.
    expect(settings.sectionPreorders('Main').single.productId, 11);
    expect(settings.preordersFor(tableId: five.id, section: 'Main').single.productId, 12);
  });

  testWidgets('a table put back on the room follows it again', (t) async {
    settings.setSectionPreorders('Main', const [TablePreorder(productId: 11)]);
    settings.setTablePreorders(five.id, const [TablePreorder(productId: 12)]);
    await t.pumpWidget(app());

    await t.tap(find.byKey(Key('preorder-follow-${five.id}')));
    await t.pumpAndSettle();

    expect(settings.tablePreorders(five.id), isNull);
    expect(find.text('Same as the section'), findsNWidgets(2));
  });

  testWidgets('a table can be emptied while the room keeps its cover charge',
      (t) async {
    settings.setSectionPreorders('Main', const [TablePreorder(productId: 11)]);
    settings.setTablePreorders(five.id, const [TablePreorder(productId: 12)]);
    await t.pumpWidget(app());

    await t.tap(find.descendant(
        of: find.byKey(Key('preorder-table-${five.id}-line-0')),
        matching: find.byIcon(Icons.remove_circle_outline)));
    await t.pumpAndSettle();

    // Emptied on purpose, which is a different answer from following the room: the
    // screen has to keep saying so, and the store has to keep storing it.
    expect(settings.tablePreorders(five.id), isEmpty);
    expect(settings.preordersFor(tableId: five.id, section: 'Main'), isEmpty);
    expect(find.textContaining('on purpose'), findsOneWidget);
  });

  testWidgets('a product the menu has lost is named as gone, not as an id', (t) async {
    settings.setSectionPreorders('Main', const [TablePreorder(productId: 999)]);
    await t.pumpWidget(app());

    expect(find.text('Product no longer in the menu'), findsOneWidget);
    expect(find.text('999'), findsNothing);
  });

  testWidgets('the search narrows the menu down', (t) async {
    await t.pumpWidget(app());

    await t.tap(find.byKey(const Key('preorder-section-add')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('preorder-product-search')), 'Wat');
    await t.pumpAndSettle();

    expect(find.byKey(const Key('preorder-product-12')), findsOneWidget);
    expect(find.byKey(const Key('preorder-product-11')), findsNothing);
  });
}
