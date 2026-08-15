import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/app/pos_session.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/features/sell/modifier_sheet.dart';
import 'package:offline_pos/features/sell/sell_screen.dart';

import '../db/sqlite_loader.dart';

/// A modifier group the shop has already decided the answer to should not stop the
/// cashier. One that still has a real choice in it must.
void main() {
  late Db db;
  late CatalogueStore cat;
  late PosSession session;

  const pizza = Product(id: 10, name: 'Margherita', price: 100, categoryId: 1);

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    cat = CatalogueStore(db);
  });
  tearDown(() => db.close());

  void seed(List<ModifierGroup> groups) {
    cat.replaceAll(
      categories: const [Category(id: 1, name: 'Pizza')],
      products: const [pizza],
      groups: groups,
      productGroupIds: {10: groups.map((g) => g.id).toList()},
      refreshedAt: DateTime.now().toUtc(),
    );
    session = PosSession(
      catalogue: cat,
      orders: OrderStore(db),
      outbox: Outbox(store: SqliteOutboxStore(db), senders: const {}),
      audit: AuditLog(db),
      deviceId: 'till-1',
      cashierId: 'sara',
    );
  }

  Future<void> tapPizza(WidgetTester t) async {
    await t.pumpWidget(MaterialApp(
      home: SellScreen(session: session, formatAmount: (v) => v.toStringAsFixed(2)),
    ));
    await t.tap(find.byKey(const Key('product-10')));
    await t.pumpAndSettle();
  }

  testWidgets('a group that answers itself never opens the sheet', (t) async {
    seed(const [
      ModifierGroup(
        id: 100,
        name: 'Sauce',
        required: true,
        minSelection: 1,
        maxSelection: 1,
        autoAdd: true,
        modifiers: [
          Modifier(id: 1000, groupId: 100, name: 'Tomato', price: 0, isDefault: true),
          Modifier(id: 1001, groupId: 100, name: 'White', price: 5),
        ],
      ),
    ]);

    await tapPizza(t);

    expect(find.byType(ModifierSheet), findsNothing);
    final line = session.current.lines.single;
    expect(line.modifiers.single.name, 'Tomato');
  });

  testWidgets('a group with a real choice still asks', (t) async {
    seed(const [
      ModifierGroup(
        id: 100,
        name: 'Sauce',
        required: true,
        minSelection: 1,
        maxSelection: 1,
        modifiers: [
          Modifier(id: 1000, groupId: 100, name: 'Tomato', price: 0, isDefault: true),
          Modifier(id: 1001, groupId: 100, name: 'White', price: 5),
        ],
      ),
    ]);

    await tapPizza(t);

    expect(find.byType(ModifierSheet), findsOneWidget);
    expect(session.current.lines, isEmpty);
  });

  testWidgets('one unresolved group is enough to ask about all of them', (t) async {
    seed(const [
      ModifierGroup(
        id: 100,
        name: 'Sauce',
        autoAdd: true,
        maxSelection: 1,
        modifiers: [
          Modifier(id: 1000, groupId: 100, name: 'Tomato', price: 0, isDefault: true),
        ],
      ),
      ModifierGroup(
        id: 101,
        name: 'Size',
        required: true,
        minSelection: 1,
        maxSelection: 1,
        autoAdd: true,
        modifiers: [
          Modifier(id: 1010, groupId: 101, name: 'Large', price: 20),
        ],
      ),
    ]);

    // Size is auto-add but has no default, so it cannot satisfy its own minimum.
    await tapPizza(t);

    expect(find.byType(ModifierSheet), findsOneWidget);
  });

  test('the flags survive the catalogue store', () {
    seed(const [
      ModifierGroup(
        id: 100,
        name: 'Sauce',
        autoAdd: true,
        maxSelection: 1,
        modifiers: [
          Modifier(id: 1000, groupId: 100, name: 'Tomato', price: 0, isDefault: true),
          Modifier(id: 1001, groupId: 100, name: 'White', price: 5),
        ],
      ),
    ]);
    final group = cat.modifierGroupsFor(10).single;
    expect(group.autoAdd, isTrue);
    expect(group.defaults.single.name, 'Tomato');
    expect(group.resolvesItself, isTrue);
  });

  test('a group cannot auto-add more options than it allows', () {
    const group = ModifierGroup(
      id: 100,
      name: 'Sauce',
      autoAdd: true,
      maxSelection: 1,
      modifiers: [
        Modifier(id: 1, groupId: 100, name: 'Tomato', price: 0, isDefault: true),
        Modifier(id: 2, groupId: 100, name: 'White', price: 0, isDefault: true),
      ],
    );
    expect(group.defaults, hasLength(1));
    expect(group.resolvesItself, isTrue);
  });
}
