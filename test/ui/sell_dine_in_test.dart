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

void main() {
  late Db db;
  late PosSession session;
  late OrderStore orders;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    final cat = CatalogueStore(db);
    cat.replaceAll(
      categories: const [Category(id: 1, name: 'Food')],
      products: const [
        Product(id: 10, name: 'Pizza', price: 100, categoryId: 1),
        Product(id: 11, name: 'Cola', price: 20, categoryId: 1),
      ],
      groups: const [],
      productGroupIds: const {},
      refreshedAt: DateTime.now().toUtc(),
    );
    orders = OrderStore(db);
    session = PosSession(
      catalogue: cat,
      orders: orders,
      outbox: Outbox(store: SqliteOutboxStore(db), senders: const {}),
      audit: AuditLog(db),
      deviceId: 'till-1',
      cashierId: 'sara',
    );
  });
  tearDown(() => db.close());

  Widget app({List<String>? tables, List<Order> Function()? heldOrders}) => MaterialApp(
        home: SellScreen(
          session: session,
          formatAmount: (v) => v.toStringAsFixed(2),
          tables: tables == null ? null : () => tables,
          heldOrders: heldOrders,
        ),
      );

  testWidgets('the split/move chip appears once a dine-in order has lines', (t) async {
    await t.pumpWidget(app());
    expect(find.byKey(const Key('bill-options')), findsNothing);
    await t.tap(find.byKey(const Key('product-10')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('bill-options')), findsOneWidget);
  });

  testWidgets('bill options offers split, pay-selected, move and merge', (t) async {
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('product-10')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('bill-options')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('bill-split-guest')), findsOneWidget);
    expect(find.byKey(const Key('bill-pay-selected')), findsOneWidget);
    expect(find.byKey(const Key('bill-move')), findsOneWidget);
    expect(find.byKey(const Key('bill-merge')), findsOneWidget);
  });

  testWidgets('moving a line opens a tab on the destination table and trims here',
      (t) async {
    await t.pumpWidget(app(tables: ['5']));
    await t.tap(find.byKey(const Key('product-10'))); // Pizza
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('product-11'))); // Cola
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('bill-options')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('bill-move')));
    await t.pumpAndSettle();

    // Tick the Cola line in the checklist, confirm, then pick table 5.
    await t.tap(find.widgetWithText(CheckboxListTile, 'Cola'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('pick-confirm')));
    await t.pumpAndSettle();
    // The visual floor picker opens; tap the destination table tile.
    await t.tap(find.byKey(const Key('table-tile-5')));
    await t.pumpAndSettle();

    // Pizza stays here; Cola is now a held tab on table 5.
    expect(session.current.lines.single.productId, 10);
    final moved = orders.held().firstWhere((o) => o.tableLabel == '5');
    expect(moved.lines.single.productId, 11);
  });

  testWidgets('merging folds another open table into the current order', (t) async {
    // A held order on table 9 with a Cola.
    final other = Order(deviceId: 'till-1', cashierId: 'sara', tableLabel: '9')
      ..state = OrderState.held
      ..lines.add(OrderLine(productId: 11, name: 'Cola', quantity: 1, unitPrice: 20));
    orders.save(other);

    await t.pumpWidget(app(heldOrders: () => orders.held()));
    await t.tap(find.byKey(const Key('product-10'))); // Pizza on the current order
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('bill-options')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('bill-merge')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('merge-${other.uuid}')));
    await t.pumpAndSettle();

    expect(session.current.lines.map((l) => l.productId).toSet(), {10, 11});
    expect(orders.byUuid(other.uuid), isNull);
  });
}
