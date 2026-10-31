import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/app/pos_app.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/auth/auth_service.dart';
import 'package:offline_pos/core/auth/user_store.dart';
import 'package:offline_pos/core/config/till_config.dart';
import 'package:offline_pos/core/db/attendance_store.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/customer_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/db/shift_store.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/db/table_store.dart';
import 'package:offline_pos/core/onboarding/wizard_id.dart';
import 'package:offline_pos/core/onboarding/wizard_store.dart';
import 'package:offline_pos/core/printing/printer_discovery.dart';
import 'package:offline_pos/core/printing/printer_registry.dart';
import 'package:offline_pos/core/sync/odoo_endpoint.dart';
import 'package:offline_pos/core/sync/odoo_wiring.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/core/sync/sync_service.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/orders/open_orders_screen.dart';
import 'package:offline_pos/features/sell/sell_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// Deleting a parked order from the Open orders list.
///
/// Only an order the kitchen never saw goes from the list, after a confirmation.
/// One with anything sent is refused there and opened instead, so taking it off
/// goes through the void inside: manager PIN, reason, kitchen cancel, reports.
void main() {
  late Db db;
  late OrderStore orders;
  late AuditLog audit;

  const cash = PaymentMethod(id: 1, name: 'Cash', isCash: true);

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    orders = OrderStore(db);
    audit = AuditLog(db);
    SettingsStore(db);
    ShiftStore(db).openShift(openingFloat: 100, cashierId: 'sara');
    TableStore(db).add(name: '5', seats: 4);
    CatalogueStore(db).replaceAll(
      categories: const [Category(id: 1, name: 'Pizza')],
      products: const [Product(id: 10, name: 'Margherita', price: 250, categoryId: 1)],
      groups: const [],
      productGroupIds: const {},
      paymentMethods: const [cash],
      refreshedAt: DateTime.now().toUtc(),
    );
    await AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'sara', name: 'Sara', pin: '1234', role: 'manager');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');
  });
  tearDown(() => db.close());

  Order parkedTab({required bool sent}) {
    final tab = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      type: OrderType.dineIn,
      tableLabel: '5',
    )
      ..state = OrderState.held
      ..lines.add(OrderLine(
          productId: 10, name: 'Margherita', quantity: 1, unitPrice: 250)
        ..printedToKitchen = sent);
    orders.save(tab, announce: false);
    return tab;
  }

  Widget app() {
    final outbox = Outbox(store: SqliteOutboxStore(db), senders: {});
    return PosApp(
      auth: AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit),
      users: UserStore(db),
      catalogue: CatalogueStore(db),
      orders: orders,
      outbox: outbox,
      audit: audit,
      sync: SyncService(
        outbox: outbox,
        catalogue: CatalogueStore(db),
        outboxStore: SqliteOutboxStore(db),
        deviceId: 'till-1',
        appVersion: 'test',
      ),
      outboxStore: SqliteOutboxStore(db),
      printers: PrinterRegistry(discovery: _NoPrinters()),
      wizards: WizardStore(db),
      shifts: ShiftStore(db),
      deviceId: 'till-1',
      endpoints: OdooEndpointStore(db),
      odoo: OdooWiring(outbox: outbox),
      tables: TableStore(db),
      settings: SettingsStore(db)..lanRolePromptDismissed = true,
      customers: CustomerStore(db),
      attendance: AttendanceStore(db),
      config: const TillConfig(),
    );
  }

  Future<void> onTheList(WidgetTester t) async {
    t.view.physicalSize = const Size(1000, 2400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('user-sara')));
    await t.pumpAndSettle();
    for (final d in '1234'.split('')) {
      await t.tap(find.byKey(Key('key-$d')));
      await t.pump();
    }
    await t.tap(find.byKey(const Key('pin-ok')));
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 50));
      if (find.byKey(const Key('pin-ok')).evaluate().isEmpty) break;
    }
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Open navigation menu'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-open-orders')));
    await t.pumpAndSettle();
    expect(find.byType(OpenOrdersScreen), findsOneWidget);
  }

  testWidgets('an order sent to the kitchen is not deleted from the list',
      (t) async {
    final tab = parkedTab(sent: true);
    await onTheList(t);

    await t.tap(find.byKey(Key('cancel-order-${tab.uuid}')));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('cancel-sent-order-refused')), findsOneWidget);
    await t.tap(find.text('Close'));
    await t.pumpAndSettle();
    expect(orders.byUuid(tab.uuid), isNotNull);
    expect(find.byType(OpenOrdersScreen), findsOneWidget);
  });

  testWidgets('the refusal opens the order, where the void is done', (t) async {
    final tab = parkedTab(sent: true);
    await onTheList(t);

    await t.tap(find.byKey(Key('cancel-order-${tab.uuid}')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('cancel-sent-order-open')));
    await t.pumpAndSettle();

    expect(find.byType(SellScreen), findsOneWidget);
    expect(find.byKey(Key('line-${tab.lines.single.uuid}')), findsOneWidget);
    expect(orders.byUuid(tab.uuid), isNotNull);
  });

  testWidgets('an order the kitchen never saw goes after a confirmation',
      (t) async {
    final tab = parkedTab(sent: false);
    await onTheList(t);

    await t.tap(find.byKey(Key('cancel-order-${tab.uuid}')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('cancel-sent-order-refused')), findsNothing);
    await t.tap(find.byKey(const Key('confirm-cancel-order')));
    await t.pumpAndSettle();

    expect(orders.byUuid(tab.uuid), isNull);
  });

  testWidgets('backing out of the confirmation keeps the order', (t) async {
    final tab = parkedTab(sent: false);
    await onTheList(t);

    await t.tap(find.byKey(Key('cancel-order-${tab.uuid}')));
    await t.pumpAndSettle();
    await t.tap(find.text('Keep'));
    await t.pumpAndSettle();

    expect(orders.byUuid(tab.uuid), isNotNull);
  });
}
