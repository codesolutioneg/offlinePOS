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
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/sell/sell_screen.dart';

import '../db/sqlite_loader.dart';

/// The table asks for the bill: the waiter prints it and carries it over, and the
/// order is still open when he gets back.
void main() {
  late Db db;
  late PosSession session;
  late List<Order> printed;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    final cat = CatalogueStore(db);
    cat.replaceAll(
      categories: const [Category(id: 1, name: 'Food')],
      products: const [Product(id: 10, name: 'Pizza', price: 100, categoryId: 1)],
      groups: const [],
      productGroupIds: const {},
      refreshedAt: DateTime.now().toUtc(),
    );
    printed = [];
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

  Widget app({bool wired = true}) => MaterialApp(
        home: SellScreen(
          session: session,
          formatAmount: (v) => v.toStringAsFixed(2),
          onPrintBill: wired ? printed.add : null,
        ),
      );

  testWidgets('the bill button only appears once the order has lines', (t) async {
    await t.pumpWidget(app());
    expect(find.byKey(const Key('print-bill')), findsNothing);

    await t.tap(find.byKey(const Key('product-10')));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('print-bill')), findsOneWidget);
  });

  testWidgets('a till with nowhere to print shows no bill button', (t) async {
    await t.pumpWidget(app(wired: false));
    await t.tap(find.byKey(const Key('product-10')));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('print-bill')), findsNothing);
    // And the menu that carries the same action hides it too.
    await t.tap(find.byKey(const Key('bill-options')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('bill-print')), findsNothing);
  });

  testWidgets('tapping the bill button hands the open order over and says so',
      (t) async {
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('product-10')));
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('print-bill')));
    await t.pumpAndSettle();

    expect(printed.single, session.current);
    expect(find.byKey(const Key('bill-printed')), findsOneWidget);
  });

  testWidgets('the split/move menu carries the same action', (t) async {
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('product-10')));
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('bill-options')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('bill-print')));
    await t.pumpAndSettle();

    expect(printed.single, session.current);
  });

  testWidgets('printing the bill changes nothing about the order', (t) async {
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('product-10')));
    await t.pumpAndSettle();
    final before = session.current.toMap();

    // Twice, because a table that asks again must not be charged twice or moved on.
    await t.tap(find.byKey(const Key('print-bill')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('print-bill')));
    await t.pumpAndSettle();

    expect(session.current.toMap(), before);
    expect(session.current.state, OrderState.draft);
    expect(session.current.lines, hasLength(1));
    expect(session.current.payments, isEmpty);
    expect(printed, hasLength(2));
  });
}
