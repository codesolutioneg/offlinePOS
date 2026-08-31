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

/// The shop owner's complaint: "no editing no removing". A choice made while ringing
/// was final, so the only way to correct a wrong size was to void the line and start
/// the item again. These drive the correction path through the real screen.
void main() {
  late Db db;
  late CatalogueStore cat;
  late AuditLog audit;
  late PosSession session;

  const pizza = Product(id: 10, name: 'Margherita', price: 100, categoryId: 1);
  const water = Product(id: 11, name: 'Water', price: 10, categoryId: 1);

  // One slot, not required, so a choice can be swapped and also cleared entirely.
  const size = ModifierGroup(
    id: 100,
    name: 'Size',
    maxSelection: 1,
    modifiers: [
      Modifier(id: 1000, groupId: 100, name: 'Large', price: 20),
      Modifier(id: 1001, groupId: 100, name: 'Small', price: 0),
    ],
  );

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    cat = CatalogueStore(db);
    audit = AuditLog(db);
    cat.replaceAll(
      categories: const [Category(id: 1, name: 'Pizza')],
      products: const [pizza, water],
      groups: const [size],
      productGroupIds: const {10: [100]},
      refreshedAt: DateTime.now().toUtc(),
    );
    session = PosSession(
      catalogue: cat,
      orders: OrderStore(db),
      outbox: Outbox(store: SqliteOutboxStore(db), senders: const {}),
      audit: audit,
      deviceId: 'till-1',
      cashierId: 'sara',
    );
  });
  tearDown(() => db.close());

  Future<void> openTill(WidgetTester t) async {
    t.view.physicalSize = const Size(1200, 2400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(MaterialApp(
      home: SellScreen(session: session, formatAmount: (v) => v.toStringAsFixed(2)),
    ));
    await t.pumpAndSettle();
  }

  /// Ring the pizza and take [option] in the sheet.
  Future<void> ringPizza(WidgetTester t, {int? option}) async {
    await t.tap(find.byKey(const Key('product-10')));
    await t.pumpAndSettle();
    if (option != null) {
      await t.tap(find.byKey(Key('mod-$option')));
      await t.pumpAndSettle();
    }
    await t.tap(find.byKey(const Key('confirm-modifiers')));
    await t.pumpAndSettle();
  }

  /// Open the per-line action sheet for [uuid] by tapping its row in the cart.
  Future<void> openLineActions(WidgetTester t, String uuid, String name) async {
    await t.tap(find.descendant(
        of: find.byKey(Key('line-$uuid')), matching: find.text(name)));
    await t.pumpAndSettle();
  }

  testWidgets('only an item with choices offers the modifier entry', (t) async {
    await openTill(t);
    await t.tap(find.byKey(const Key('product-11')));
    await t.pumpAndSettle();

    await openLineActions(t, session.current.lines.single.uuid, 'Water');
    expect(find.byKey(const Key('line-modifiers')), findsNothing,
        reason: 'an item with no groups would open an empty sheet');
    await t.tapAt(const Offset(1, 1));
    await t.pumpAndSettle();

    // The same menu on an item that does carry choices offers it.
    await ringPizza(t, option: 1000);
    await openLineActions(
        t, session.current.lines.firstWhere((l) => l.name == 'Margherita').uuid,
        'Margherita');
    expect(find.byKey(const Key('line-modifiers')), findsOneWidget);
  });

  testWidgets('the entry reopens the sheet showing what the line already carries',
      (t) async {
    await openTill(t);
    await ringPizza(t, option: 1000);

    await openLineActions(t, session.current.lines.single.uuid, 'Margherita');
    expect(find.byKey(const Key('line-modifiers')), findsOneWidget);
    await t.tap(find.byKey(const Key('line-modifiers')));
    await t.pumpAndSettle();

    expect(find.byType(ModifierSheet), findsOneWidget);
    expect(t.widget<CheckboxListTile>(find.byKey(const Key('mod-1000'))).value, isTrue,
        reason: 'the cashier has to see what was chosen before changing it');
    expect(t.widget<CheckboxListTile>(find.byKey(const Key('mod-1001'))).value, isFalse);
  });

  testWidgets('changing the choice reprices the line and is audited', (t) async {
    await openTill(t);
    await ringPizza(t, option: 1000);
    expect(session.current.lines.single.total, 120);

    await openLineActions(t, session.current.lines.single.uuid, 'Margherita');
    await t.tap(find.byKey(const Key('line-modifiers')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('mod-1001')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-modifiers')));
    await t.pumpAndSettle();

    final line = session.current.lines.single;
    expect(line.modifiers.single.name, 'Small');
    expect(line.total, 100);

    final entry = audit.recent(event: 'line.modifiers_changed').single;
    expect(entry['detail'], contains('Large'));
    expect(entry['detail'], contains('Small'));
  });

  testWidgets('clearing the choice takes it off the line', (t) async {
    await openTill(t);
    await ringPizza(t, option: 1000);

    await openLineActions(t, session.current.lines.single.uuid, 'Margherita');
    await t.tap(find.byKey(const Key('line-modifiers')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('mod-1000')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-modifiers')));
    await t.pumpAndSettle();

    final line = session.current.lines.single;
    expect(line.modifiers, isEmpty);
    expect(line.total, 100);
    expect(audit.recent(event: 'line.modifiers_changed'), hasLength(1));
  });

  testWidgets('an edit that makes two plain lines identical folds them into one',
      (t) async {
    await openTill(t);
    await ringPizza(t, option: 1000);
    await ringPizza(t, option: 1001);
    expect(session.current.lines, hasLength(2));

    final small = session.current.lines.last;
    await openLineActions(t, small.uuid, 'Margherita');
    await t.tap(find.byKey(const Key('line-modifiers')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('mod-1000')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-modifiers')));
    await t.pumpAndSettle();

    final line = session.current.lines.single;
    expect(line.quantity, 2, reason: 'the cart has nothing left to tell them apart');
    expect(line.modifiers.single.name, 'Large');
  });

  testWidgets('a line the cashier marked out is not folded away by an edit',
      (t) async {
    await openTill(t);
    await ringPizza(t, option: 1000);
    session.setLineNote(session.current.lines.single.uuid, 'no basil');
    await ringPizza(t, option: 1001);

    final small = session.current.lines.last;
    await openLineActions(t, small.uuid, 'Margherita');
    await t.tap(find.byKey(const Key('line-modifiers')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('mod-1000')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-modifiers')));
    await t.pumpAndSettle();

    expect(session.current.lines, hasLength(2),
        reason: 'the noted line was kept apart on purpose');
    expect(session.current.lines.last.modifiers.single.name, 'Large');
  });

  testWidgets('a line the kitchen already has says why it cannot be changed',
      (t) async {
    await openTill(t);
    await ringPizza(t, option: 1000);
    final line = session.current.lines.single;
    line.printedToKitchen = true;

    await openLineActions(t, line.uuid, 'Margherita');
    expect(find.byKey(const Key('line-modifiers')), findsOneWidget,
        reason: 'the reason has to be readable, not a missing row');
    expect(find.text('The kitchen already has this. Void it and ring it again.'),
        findsOneWidget);
    await t.tap(find.byKey(const Key('line-modifiers')));
    await t.pumpAndSettle();

    expect(find.byType(ModifierSheet), findsNothing);
    expect(line.modifiers.single.name, 'Large');
    expect(audit.recent(event: 'line.modifiers_changed'), isEmpty);
  });

  test('the session itself refuses to restate a fired line', () {
    session.addProduct(pizza, chosen: [
      const ChosenModifier(Modifier(id: 1000, groupId: 100, name: 'Large', price: 20)),
    ]);
    final line = session.current.lines.single;
    line.printedToKitchen = true;

    session.setLineModifiers(line.uuid, const [
      ChosenModifier(Modifier(id: 1001, groupId: 100, name: 'Small', price: 0)),
    ]);

    expect(line.modifiers.single.name, 'Large');
    expect(audit.recent(event: 'line.modifiers_changed'), isEmpty);
  });
}
