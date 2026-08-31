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

/// Which category tabs a branch till offers.
///
/// The menu is filtered by branch and the categories are not, so a chain's whole
/// list arrives on every till whatever that shop sells. A tab with nothing behind
/// it reads on the counter as a till that failed to load its menu.
void main() {
  late Db db;
  late CatalogueStore cat;
  late PosSession session;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    cat = CatalogueStore(db);
    session = PosSession(
      catalogue: cat,
      orders: OrderStore(db),
      outbox: Outbox(store: SqliteOutboxStore(db), senders: const {}),
      audit: AuditLog(db),
      deviceId: 'till-1',
      cashierId: 'sara',
    );
  });
  tearDown(() => db.close());

  void stock(List<Product> products) => cat.replaceAll(
        categories: const [
          Category(id: 1, name: 'Pizza'),
          Category(id: 2, name: 'Desserts'),
        ],
        products: products,
        groups: const [],
        productGroupIds: const {},
        refreshedAt: DateTime.now().toUtc(),
      );

  Widget app() => MaterialApp(
        home: SellScreen(
          session: session,
          formatAmount: (v) => v.toStringAsFixed(2),
        ),
      );

  testWidgets('a category with nothing behind it on this till is left off',
      (t) async {
    stock(const [Product(id: 10, name: 'Margherita', price: 250, categoryId: 1)]);
    await t.pumpWidget(app());

    expect(find.byKey(const Key('cat-chip-1')), findsOneWidget);
    expect(find.byKey(const Key('cat-chip-2')), findsNothing,
        reason: 'tapping it could only ever show an empty grid');
  });

  testWidgets('the category comes back with the first dish filed under it',
      (t) async {
    // The categories are still pulled and still stored, because they cost nothing
    // and one that is empty here today may not be tomorrow. Only the tab waits.
    stock(const [Product(id: 10, name: 'Margherita', price: 250, categoryId: 1)]);
    await t.pumpWidget(app());
    expect(find.byKey(const Key('cat-chip-2')), findsNothing);

    stock(const [
      Product(id: 10, name: 'Margherita', price: 250, categoryId: 1),
      Product(id: 11, name: 'Basbousa', price: 40, categoryId: 2),
    ]);
    await t.pumpWidget(app());
    expect(find.byKey(const Key('cat-chip-2')), findsOneWidget);
  });

  testWidgets('the category being shown keeps its chip even once it empties',
      (t) async {
    // Otherwise a refresh that empties a category takes the chip out from under
    // the cashier standing in it, and the grid they are looking at has no owner.
    stock(const [
      Product(id: 10, name: 'Margherita', price: 250, categoryId: 1),
      Product(id: 11, name: 'Basbousa', price: 40, categoryId: 2),
    ]);
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('cat-chip-2')));
    await t.pumpAndSettle();

    stock(const [Product(id: 10, name: 'Margherita', price: 250, categoryId: 1)]);
    await t.pumpWidget(app());
    expect(find.byKey(const Key('cat-chip-2')), findsOneWidget);
  });
}
