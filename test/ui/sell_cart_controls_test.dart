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

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    final cat = CatalogueStore(db);
    cat.replaceAll(
      categories: const [Category(id: 1, name: 'Mains')],
      products: const [
        Product(id: 10, name: 'Burger', price: 100, categoryId: 1),
        Product(id: 11, name: 'Water', price: 10, categoryId: 1),
      ],
      groups: const [],
      productGroupIds: const {},
      refreshedAt: DateTime.now().toUtc(),
    );
    session = PosSession(
      catalogue: cat,
      orders: OrderStore(db),
      outbox: Outbox(store: SqliteOutboxStore(db), senders: const {}),
      audit: AuditLog(db),
      deviceId: 'till-1',
      cashierId: '7',
    );
  });
  tearDown(() => db.close());

  Future<void> open(WidgetTester t) async {
    t.view.physicalSize = const Size(1366, 768);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: SellScreen(
        session: session,
        formatAmount: (v) => v.toStringAsFixed(2),
        staffName: (id) => id == '7' ? 'Administrator' : null,
      ),
    ));
    await t.pump();
  }

  OrderLine line(int productId) =>
      session.current.lines.firstWhere((l) => l.productId == productId);

  testWidgets('green strips say what screen, which table and whose check',
      (t) async {
    session.setOrderType(OrderType.dineIn);
    session.setTable('24');
    await open(t);
    expect(find.byKey(const Key('order-entry-clock')), findsOneWidget);
    expect(
        t.widget<Text>(find.byKey(const Key('order-entry-title'))).data,
        contains('ORDER ENTRY'));
    expect(t.widget<Text>(find.byKey(const Key('status-table'))).data,
        'TABLE: 24');
    expect(t.widget<Text>(find.byKey(const Key('status-empl'))).data,
        'EMPLOYEE: Administrator (7)');
    expect(t.widget<Text>(find.byKey(const Key('status-discount'))).data,
        'DISCOUNT: 0.00%');
  });

  testWidgets('the line just rung is picked, and Qty (+)/(-) step it',
      (t) async {
    await open(t);
    await t.tap(find.byKey(const Key('product-10')));
    await t.pump();
    await t.tap(find.byKey(const Key('cart-qty-plus')));
    await t.pump();
    expect(line(10).quantity, 2);
    await t.tap(find.byKey(const Key('cart-qty-minus')));
    await t.pump();
    expect(line(10).quantity, 1);
  });

  testWidgets('Seat (+)/(-) moves the whole line from guest to guest',
      (t) async {
    await open(t);
    await t.tap(find.byKey(const Key('product-10')));
    await t.pump();
    await t.tap(find.byKey(const Key('cart-qty-plus')));
    await t.pump();
    await t.tap(find.byKey(const Key('cart-seat-plus')));
    await t.pump();
    await t.tap(find.byKey(const Key('cart-seat-plus')));
    await t.pump();
    expect(session.current.lines, hasLength(1));
    expect(line(10).seat, 2);
    expect(line(10).quantity, 2);
    await t.tap(find.byKey(const Key('cart-seat-minus')));
    await t.tap(find.byKey(const Key('cart-seat-minus')));
    await t.pump();
    expect(line(10).seat, isNull);
  });

  testWidgets('Up / All / Btm move the pick', (t) async {
    await open(t);
    await t.tap(find.byKey(const Key('product-10')));
    await t.pump();
    await t.tap(find.byKey(const Key('product-11')));
    await t.pump();

    await t.tap(find.byKey(const Key('cart-up')));
    await t.pump();
    await t.tap(find.byKey(const Key('cart-qty-plus')));
    await t.pump();
    expect(line(10).quantity, 2);
    expect(line(11).quantity, 1);

    await t.tap(find.byKey(const Key('cart-all')));
    await t.pump();
    await t.tap(find.byKey(const Key('cart-qty-plus')));
    await t.pump();
    expect(line(10).quantity, 3);
    expect(line(11).quantity, 2);

    await t.tap(find.byKey(const Key('cart-btm')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('cart-qty-plus')));
    await t.pump();
    expect(line(10).quantity, 3);
    expect(line(11).quantity, 3);
  });

  group('Clr deletes what is picked', () {
    testWidgets('a single item goes straight away', (t) async {
      await open(t);
      await t.tap(find.byKey(const Key('product-10')));
      await t.pump();
      await t.tap(find.byKey(const Key('product-11')));
      await t.pump();

      await t.tap(find.byKey(const Key('cart-clear')));
      await t.pumpAndSettle();

      expect(session.current.lines.map((l) => l.productId), [10]);
    });

    testWidgets('a line of several asks how many first', (t) async {
      await open(t);
      await t.tap(find.byKey(const Key('product-10')));
      await t.pump();
      session.setQuantity(line(10).uuid, 3);
      await t.pump();

      await t.tap(find.byKey(const Key('cart-clear')));
      await t.pumpAndSettle();
      expect(find.text('How many to delete?'), findsOneWidget);
      await t.tap(find.byKey(const Key('void-qty-plus')));
      await t.pump();
      await t.tap(find.byKey(const Key('confirm-void-qty')));
      await t.pumpAndSettle();

      expect(line(10).quantity, 1);
    });

    testWidgets('cancelling the count leaves the line alone', (t) async {
      await open(t);
      await t.tap(find.byKey(const Key('product-10')));
      await t.pump();
      session.setQuantity(line(10).uuid, 3);
      await t.pump();

      await t.tap(find.byKey(const Key('cart-clear')));
      await t.pumpAndSettle();
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();

      expect(line(10).quantity, 3);
    });

    testWidgets('several picked lines are confirmed, then all go', (t) async {
      await open(t);
      await t.tap(find.byKey(const Key('product-10')));
      await t.pump();
      await t.tap(find.byKey(const Key('product-11')));
      await t.pump();
      await t.tap(find.byKey(const Key('cart-all')));
      await t.pump();

      await t.tap(find.byKey(const Key('cart-clear')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('confirm-delete-many')), findsOneWidget);
      await t.tap(find.byKey(const Key('confirm-delete-many-ok')));
      await t.pumpAndSettle();

      expect(session.current.lines, isEmpty);
    });
  });

  testWidgets('tapping a line picks it; tapping it again opens its menu',
      (t) async {
    await open(t);
    await t.tap(find.byKey(const Key('product-10')));
    await t.pump();
    await t.tap(find.byKey(const Key('product-11')));
    await t.pump();
    final burger = line(10).uuid;
    await t.tap(find.byKey(Key('line-$burger')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('line-split-units')), findsNothing);
    await t.tap(find.byKey(const Key('cart-qty-plus')));
    await t.pump();
    expect(line(10).quantity, 2);
    await t.tap(find.byKey(Key('line-$burger')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('line-split-units')), findsOneWidget);
  });

  group('a long bill keeps the line just rung in view', () {
    bool inView(WidgetTester t, String uuid) {
      final list = t.getRect(find.byKey(const Key('cart-list')));
      final row = find.byKey(Key('line-$uuid'));
      return row.evaluate().isNotEmpty && list.contains(t.getRect(row).center);
    }

    setUp(() {
      session.addProduct(
          const Product(id: 10, name: 'Burger', price: 100, categoryId: 1));
      for (var i = 0; i < 30; i++) {
        session.current.lines.add(
            OrderLine(productId: 100 + i, name: 'Dish $i', quantity: 1, unitPrice: 5));
      }
      session.orders.save(session.current);
    });

    testWidgets('a new line at the bottom scrolls down to it', (t) async {
      await open(t);
      await t.tap(find.byKey(const Key('product-11')));
      await t.pumpAndSettle();
      expect(inView(t, line(11).uuid), isTrue);
    });

    testWidgets('another tap on a product higher up scrolls back to it',
        (t) async {
      await open(t);
      await t.tap(find.byKey(const Key('product-11')));
      await t.pumpAndSettle();
      expect(inView(t, line(10).uuid), isFalse);

      await t.tap(find.byKey(const Key('product-10')));
      await t.pumpAndSettle();
      expect(line(10).quantity, 2);
      expect(inView(t, line(10).uuid), isTrue);
    });
  });

  testWidgets('the page counter reads 1 / 1 on a short bill', (t) async {
    await open(t);
    await t.tap(find.byKey(const Key('product-10')));
    await t.pumpAndSettle();
    expect(t.widget<Text>(find.byKey(const Key('cart-page'))).data, '1 / 1');
  });
}
