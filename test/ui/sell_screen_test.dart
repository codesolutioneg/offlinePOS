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
import 'package:offline_pos/features/sell/sell_screen.dart';

import '../db/sqlite_loader.dart';

void main() {
  late Db db;
  late CatalogueStore cat;
  late PosSession session;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    cat = CatalogueStore(db);
    cat.replaceAll(
      categories: const [Category(id: 1, name: 'Pizza')],
      products: const [
        Product(id: 10, name: 'Margherita', price: 250, categoryId: 1),
        Product(id: 11, name: 'Water', price: 10, categoryId: 1),
      ],
      groups: const [
        ModifierGroup(id: 100, name: 'Toppings', maxSelection: 2, modifiers: [
          Modifier(id: 1000, groupId: 100, name: 'Cheese', price: 7),
          Modifier(id: 1001, groupId: 100, name: 'Ten Pct', price: 10,
              priceType: ModifierPriceType.percentage),
        ]),
      ],
      productGroupIds: const {10: [100]},
      refreshedAt: DateTime.now().toUtc(),
    );
    session = PosSession(
      catalogue: cat, orders: OrderStore(db),
      outbox: Outbox(store: SqliteOutboxStore(db), senders: const {}),
      audit: AuditLog(db), deviceId: 'till-1', cashierId: 'sara',
    );
  });
  tearDown(() => db.close());

  Widget app({
    Duration? staleness,
    VoidCallback? onSignOut,
    VoidCallback? onChanged,
  }) =>
      MaterialApp(
        home: SellScreen(
          session: session,
          formatAmount: (v) => v.toStringAsFixed(2),
          staleness: staleness,
          onSignOut: onSignOut,
          onChanged: onChanged,
        ),
      );

  testWidgets('shows the catalogue from local storage', (t) async {
    await t.pumpWidget(app());
    expect(find.text('Margherita'), findsOneWidget);
    expect(find.text('Water'), findsOneWidget);
  });

  testWidgets('a product with no modifiers goes straight onto the order', (t) async {
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('product-11')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('total')), findsOneWidget);
    expect(find.text('10.00'), findsWidgets);
  });

  testWidgets('a product with modifiers opens the picker', (t) async {
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('product-10')));
    await t.pumpAndSettle();
    expect(find.text('Toppings'), findsOneWidget);
    expect(find.byKey(const Key('mod-1000')), findsOneWidget);
  });

  testWidgets('a percentage option is shown as a percentage, not money', (t) async {
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('product-10')));
    await t.pumpAndSettle();
    expect(find.text('+10%'), findsOneWidget);
    expect(find.text('+7.00'), findsOneWidget);
  });

  testWidgets('choosing modifiers prices them against the parent', (t) async {
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('product-10')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('mod-1001'))); // 10% of 250 = 25
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-modifiers')));
    await t.pumpAndSettle();
    expect(session.total, 275);
  });

  testWidgets('exceeding the group maximum blocks confirmation', (t) async {
    // Rebuild with a group that allows only one.
    cat.replaceAll(
      categories: const [], products: const [Product(id: 20, name: 'Combo', price: 100)],
      groups: const [
        ModifierGroup(id: 200, name: 'Size', required: true, maxSelection: 1, modifiers: [
          Modifier(id: 2000, groupId: 200, name: 'S', price: 0),
          Modifier(id: 2001, groupId: 200, name: 'L', price: 5),
        ]),
      ],
      productGroupIds: const {20: [200]}, refreshedAt: DateTime.now().toUtc(),
    );
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('product-20')));
    await t.pumpAndSettle();
    // Required and nothing chosen: cannot confirm.
    final button = t.widget<FilledButton>(find.byKey(const Key('confirm-modifiers')));
    expect(button.onPressed, isNull);
    expect(find.byKey(const Key('validation')), findsOneWidget);
  });

  testWidgets('a single-choice group swaps instead of stacking', (t) async {
    cat.replaceAll(
      categories: const [], products: const [Product(id: 20, name: 'Combo', price: 100)],
      groups: const [
        ModifierGroup(id: 200, name: 'Size', maxSelection: 1, modifiers: [
          Modifier(id: 2000, groupId: 200, name: 'S', price: 0),
          Modifier(id: 2001, groupId: 200, name: 'L', price: 5),
        ]),
      ],
      productGroupIds: const {20: [200]}, refreshedAt: DateTime.now().toUtc(),
    );
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('product-20')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('mod-2000')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('mod-2001')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-modifiers')));
    await t.pumpAndSettle();
    expect(session.current.lines.single.modifiers.length, 1);
    expect(session.total, 105);
  });

  testWidgets('a quantity group takes a count of each item up to its total',
      (t) async {
    // "Choose 3 from the list": a box that is filled by the count of each option,
    // one option capped at two of itself.
    cat.replaceAll(
      categories: const [],
      products: const [Product(id: 30, name: 'Box', price: 100)],
      groups: const [
        ModifierGroup(
          id: 300,
          name: 'Pick 3',
          minSelection: 3,
          maxSelection: 3,
          modifiers: [
            Modifier(id: 3000, groupId: 300, name: 'Chicken', price: 0, maxQuantity: 2),
            Modifier(id: 3001, groupId: 300, name: 'Beef', price: 0),
          ],
        ),
      ],
      productGroupIds: const {30: [300]}, refreshedAt: DateTime.now().toUtc(),
    );
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('product-30')));
    await t.pumpAndSettle();
    // The stepper is on the row from the start, before anything is ticked: the
    // cashier sets how many of the item, not just whether to take it.
    expect(find.byKey(const Key('mod-3000-plus')), findsOneWidget);

    await t.tap(find.byKey(const Key('mod-3000-plus')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('mod-3000-plus')));
    await t.pumpAndSettle();
    // Chicken caps at two of itself; a third tap does nothing.
    expect(t.widget<IconButton>(find.byKey(const Key('mod-3000-plus'))).onPressed,
        isNull);

    // Two chosen, one short of the box: the order cannot be confirmed yet.
    expect(t.widget<FilledButton>(find.byKey(const Key('confirm-modifiers'))).onPressed,
        isNull);

    await t.tap(find.byKey(const Key('mod-3001-plus')));
    await t.pumpAndSettle();
    // The box is full at three, so every plus is now frozen.
    expect(t.widget<IconButton>(find.byKey(const Key('mod-3001-plus'))).onPressed,
        isNull);

    await t.tap(find.byKey(const Key('confirm-modifiers')));
    await t.pumpAndSettle();
    final mods = session.current.lines.single.modifiers;
    expect(mods.firstWhere((m) => m.name == 'Chicken').quantity, 2);
    expect(mods.firstWhere((m) => m.name == 'Beef').quantity, 1);
  });

  testWidgets('a checkbox group refuses a tick past its cap', (t) async {
    // "Choose two" must actually stop at two: the third tick does nothing rather
    // than being taken and only failing at the confirm button.
    cat.replaceAll(
      categories: const [],
      products: const [Product(id: 40, name: 'Plate', price: 100)],
      groups: const [
        ModifierGroup(id: 400, name: 'Sides', maxSelection: 2, modifiers: [
          Modifier(id: 4000, groupId: 400, name: 'Rice', price: 0),
          Modifier(id: 4001, groupId: 400, name: 'Fries', price: 0),
          Modifier(id: 4002, groupId: 400, name: 'Salad', price: 0),
        ]),
      ],
      productGroupIds: const {40: [400]}, refreshedAt: DateTime.now().toUtc(),
    );
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('product-40')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('mod-4000')));
    await t.tap(find.byKey(const Key('mod-4001')));
    await t.pumpAndSettle();
    // The cap is reached; the third option cannot be added at all.
    expect(t.widget<IconButton>(find.byKey(const Key('mod-4002-plus'))).onPressed,
        isNull);
    await t.tap(find.byKey(const Key('mod-4002')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-modifiers')));
    await t.pumpAndSettle();
    final mods = session.current.lines.single.modifiers;
    expect(mods.length, 2);
    expect(mods.any((m) => m.name == 'Salad'), isFalse);
  });

  testWidgets('payment clears the order and queues it', (t) async {
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('product-11')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('pay')));
    await t.pumpAndSettle();
    // The tender sheet opens; the sale completes only on confirmation.
    expect(find.byKey(const Key('confirm-payment')), findsOneWidget);
    expect(session.hasLines, isTrue);
    await t.tap(find.byKey(const Key('confirm-payment')));
    await t.pumpAndSettle();
    expect(session.hasLines, isFalse);
  });

  testWidgets('pay is disabled with an empty order', (t) async {
    await t.pumpWidget(app());
    final button = t.widget<FilledButton>(find.byKey(const Key('pay')));
    expect(button.onPressed, isNull);
  });

  testWidgets('a stale catalogue is called out rather than hidden', (t) async {
    await t.pumpWidget(app(staleness: const Duration(days: 3)));
    expect(find.byKey(const Key('stale-banner')), findsOneWidget);
    expect(find.textContaining('3 day'), findsOneWidget);
  });

  testWidgets('a fresh catalogue shows no warning', (t) async {
    await t.pumpWidget(app(staleness: const Duration(hours: 2)));
    expect(find.byKey(const Key('stale-banner')), findsNothing);
  });

  testWidgets('search filters locally', (t) async {
    await t.pumpWidget(app());
    await t.enterText(find.byKey(const Key('search')), 'water');
    await t.pumpAndSettle();
    expect(find.text('Water'), findsOneWidget);
    expect(find.text('Margherita'), findsNothing);
  });

  testWidgets('a search with no matches shows an empty state instead of a blank grid',
      (t) async {
    await t.pumpWidget(app());
    await t.enterText(find.byKey(const Key('search')), 'nothing matches this');
    await t.pumpAndSettle();
    expect(find.text('No products'), findsOneWidget);
  });

  testWidgets('an empty order shows an empty state guiding the cashier to add a product',
      (t) async {
    await t.pumpWidget(app());
    expect(find.text('Start adding products'), findsOneWidget);
  });

  group('a shift can be changed on the device', () {
    testWidgets('there is a way out, so a handover does not mean killing the app',
        (t) async {
      var signedOut = false;
      await t.pumpWidget(app(onSignOut: () => signedOut = true));
      await t.tap(find.byKey(const Key('sign-out')));
      await t.pumpAndSettle();
      expect(signedOut, isTrue);
    });

    testWidgets('handing the till over mid-order is refused', (t) async {
      await t.pumpWidget(app(onSignOut: () {}));
      await t.tap(find.byKey(const Key('product-11')));
      await t.pumpAndSettle();
      // Whose sale it was is the thing that would be lost.
      expect(
        t.widget<TextButton>(find.byKey(const Key('sign-out'))).onPressed,
        isNull,
      );
    });
  });

  testWidgets('an order gaining lines is published, so the update gate can see it',
      (t) async {
    // The gate is built in the composition root, before any screen exists, and
    // this is the only honest source of "a customer is standing there".
    final states = <bool>[];
    await t.pumpWidget(app(onChanged: () => states.add(session.hasLines)));

    await t.tap(find.byKey(const Key('product-11')));
    await t.pumpAndSettle();
    expect(states, [true]);

    await t.tap(find.byIcon(Icons.delete_outline));
    await t.pumpAndSettle();
    expect(states, [true, false]);
  });

  testWidgets('New order returns to the floor home to start the next one', (t) async {
    // An order on screen so the New order button is enabled.
    session.addProduct(const Product(id: 10, name: 'Margherita', price: 250, categoryId: 1));
    var wentHome = false;
    await t.pumpWidget(MaterialApp(
      home: SellScreen(
        session: session,
        formatAmount: (v) => v.toStringAsFixed(2),
        onNewOrder: () => wentHome = true,
      ),
    ));
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('new-order')));
    await t.pumpAndSettle();
    // The shell is asked to show the floor home and decides what happens to the
    // order on the way out (it parks it). This screen touches nothing itself, so
    // the cart is exactly as it was when the callback fired.
    expect(wentHome, isTrue);
    expect(session.hasLines, isTrue);
  });

  testWidgets('a kitchen-fired line cannot be edited or trashed inline, only voided', (t) async {
    session.addProduct(const Product(id: 10, name: 'Margherita', price: 250, categoryId: 1));
    final line = session.current.lines.single;

    // Before firing: free inline controls, plain trash.
    await t.pumpWidget(app());
    await t.pumpAndSettle();
    expect(find.byIcon(Icons.add_circle_outline), findsWidgets);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    expect(find.byKey(Key('line-void-inline-${line.uuid}')), findsNothing);

    // Once the kitchen holds it, the +/- and free trash are gone; the only removal
    // path is the void affordance (which is gated, prints a slip and audits).
    line.printedToKitchen = true;
    await t.pumpWidget(app());
    await t.pumpAndSettle();
    expect(find.byIcon(Icons.add_circle_outline), findsNothing);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
    expect(find.byKey(Key('line-void-inline-${line.uuid}')), findsOneWidget);
  });
}
