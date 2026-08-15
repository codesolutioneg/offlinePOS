import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/app/pos_session.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/printing/kitchen_ticket.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/core/theme/app_colors.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/features/sell/sell_screen.dart';

import '../db/sqlite_loader.dart';

/// What the cashier is told when the kitchen ticket is fired. Before this, every
/// outcome read as "Sent to kitchen", including the one where nothing is cooking.
void main() {
  late Db db;
  late PosSession session;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    final cat = CatalogueStore(db);
    cat.replaceAll(
      categories: const [Category(id: 1, name: 'Pizza')],
      products: const [Product(id: 11, name: 'Water', price: 10, categoryId: 1)],
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
      cashierId: 'sara',
    );
    session.addProduct(const Product(id: 11, name: 'Water', price: 10, categoryId: 1));
  });
  tearDown(() => db.close());

  Future<void> fire(WidgetTester t, KitchenFireResult result) async {
    await t.pumpWidget(MaterialApp(
      home: SellScreen(
        session: session,
        formatAmount: (v) => v.toStringAsFixed(2),
        onSendToKitchen: () async => result,
      ),
    ));
    await t.tap(find.byKey(const Key('send-kitchen')));
    await t.pumpAndSettle();
  }

  Color? toastColour(WidgetTester t) =>
      t.widget<SnackBar>(find.byKey(const Key('sent-kitchen'))).backgroundColor;

  testWidgets('a printed ticket says so, in green', (t) async {
    await fire(t, KitchenFireResult.sent);
    expect(find.text('Sent to kitchen.'), findsOneWidget);
    expect(toastColour(t), AppColors.success);
  });

  testWidgets('a held ticket says the food is not cooking yet, in amber', (t) async {
    await fire(t, KitchenFireResult.spooled);
    expect(
        find.text('Ticket held, printer offline. It will print automatically.'),
        findsOneWidget);
    expect(toastColour(t), AppColors.warning);
    expect(find.text('Sent to kitchen.'), findsNothing);
  });

  testWidgets('a lost ticket tells the cashier to go and tell them, in red',
      (t) async {
    await fire(t, KitchenFireResult.lost);
    expect(find.text('Ticket did not print. Tell the kitchen and try again.'),
        findsOneWidget);
    expect(toastColour(t), AppColors.error);
  });

  testWidgets('held print jobs are visible beside the online badge', (t) async {
    await t.pumpWidget(MaterialApp(
      home: SellScreen(
        session: session,
        formatAmount: (v) => v.toStringAsFixed(2),
        spooledJobs: () => 2,
      ),
    ));
    expect(find.byKey(const Key('spool-count')), findsOneWidget);
    expect(find.text('2 to print'), findsOneWidget);
  });

  testWidgets('nothing held, nothing shown', (t) async {
    await t.pumpWidget(MaterialApp(
      home: SellScreen(
        session: session,
        formatAmount: (v) => v.toStringAsFixed(2),
        spooledJobs: () => 0,
      ),
    ));
    expect(find.byKey(const Key('spool-count')), findsNothing);
  });
}
