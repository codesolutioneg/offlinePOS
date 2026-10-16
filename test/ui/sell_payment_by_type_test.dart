import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/app/pos_session.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/domain/order.dart' show OrderType;
import 'package:offline_pos/features/sell/sell_screen.dart';

import '../db/sqlite_loader.dart';
import 'pay_button.dart';

/// The payment sheet offers what the shop takes on the order's type.
void main() {
  late Db db;
  late PosSession session;
  late SettingsStore settings;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    final cat = CatalogueStore(db)
      ..replaceAll(
        categories: const [Category(id: 1, name: 'Drinks')],
        products: const [Product(id: 11, name: 'Water', price: 10, categoryId: 1)],
        groups: const [],
        productGroupIds: const {},
        paymentMethods: const [
          PaymentMethod(id: 1, name: 'Cash', isCash: true),
          PaymentMethod(id: 2, name: 'Talabat'),
        ],
        refreshedAt: DateTime.now().toUtc(),
      );
    settings = SettingsStore(db)..lanRolePromptDismissed = true;
    session = PosSession(
      catalogue: cat, orders: OrderStore(db),
      outbox: Outbox(store: SqliteOutboxStore(db), senders: const {}),
      audit: AuditLog(db), deviceId: 'till-1', cashierId: 'sara',
    );
  });
  tearDown(() => db.close());

  Future<void> openPayment(WidgetTester t, OrderType type) async {
    session.setOrderType(type);
    await t.pumpWidget(MaterialApp(
      home: SellScreen(
        session: session,
        settings: settings,
        formatAmount: (v) => v.toStringAsFixed(2),
      ),
    ));
    await t.tap(find.byKey(const Key('product-11')));
    await t.pumpAndSettle();
    await t.tap(findPay());
    await t.pumpAndSettle();
  }

  testWidgets('a method narrowed to delivery is not offered on a takeaway', (t) async {
    settings.setPaymentMethodTypes(2, {OrderType.deliveryFromCompany});
    await openPayment(t, OrderType.takeaway);

    expect(find.byKey(const Key('method-1')), findsOneWidget);
    expect(find.byKey(const Key('method-2')), findsNothing);
  });

  testWidgets('every method is offered while nothing is narrowed', (t) async {
    await openPayment(t, OrderType.takeaway);

    expect(find.byKey(const Key('method-1')), findsOneWidget);
    expect(find.byKey(const Key('method-2')), findsOneWidget);
  });

  testWidgets('a type left with no method still offers them all', (t) async {
    settings
      ..setPaymentMethodTypes(1, {OrderType.dineIn})
      ..setPaymentMethodTypes(2, {OrderType.dineIn});
    await openPayment(t, OrderType.takeaway);

    expect(find.byKey(const Key('method-1')), findsOneWidget);
    expect(find.byKey(const Key('method-2')), findsOneWidget);
  });
}
