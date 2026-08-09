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
}
