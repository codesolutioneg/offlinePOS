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
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/sell/sell_screen.dart';
import 'package:offline_pos/features/tables/table_floor_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// A delivery desk that cannot seat a table, as the cashier meets it: no chip on
/// the sell screen, no button on the floor, and a table tap that says why.
void main() {
  late Db db;
  late OrderStore orders;
  late SettingsStore settings;
  late TableStore tables;
  late PosTable table5;
  late AuditLog audit;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    // The till refuses to start an order with no shift open, so a test that
    // sells opens the drawer first.
    ShiftStore(db).openShift(openingFloat: 100, cashierId: 'sara');
    orders = OrderStore(db);
    settings = SettingsStore(db);
    tables = TableStore(db);
    audit = AuditLog(db);
    table5 = tables.add(name: '5');
    await AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'sara', name: 'Sara', pin: '1234');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');
  });
  tearDown(() => db.close());

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
      tables: tables,
      settings: settings,
      customers: CustomerStore(db),
      attendance: AttendanceStore(db),
      config: const TillConfig(),
    );
  }

  Order draftOnTheTill({OrderType type = OrderType.takeaway}) {
    final order = Order(deviceId: 'till-1', cashierId: 'sara', type: type)
      ..lines.add(OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 100));
    orders.save(order, announce: false);
    return order;
  }

  Future<void> signIn(WidgetTester t) async {
    await t.tap(find.byKey(const Key('user-sara')));
    await t.pumpAndSettle();
    for (final d in '1234'.split('')) {
      await t.tap(find.byKey(Key('key-$d')));
      await t.pump();
    }
    await t.tap(find.byKey(const Key('pin-ok')));
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 50));
      if (find.byType(SellScreen).evaluate().isNotEmpty) break;
    }
    await t.pumpAndSettle();
  }

  /// Everything on, which is what an unconfigured till is.
  void deliveryDeskOnly() {
    settings.setRoleOrderType('cashier', OrderType.dineIn, false);
    settings.setRoleOrderType('cashier', OrderType.takeaway, false);
  }

  testWidgets('an unconfigured till offers every order type, as it always did',
      (t) async {
    draftOnTheTill();
    await t.pumpWidget(app());
    await signIn(t);

    for (final type in OrderType.values) {
      expect(find.byKey(Key('order-type-${type.name.toLowerCase()}')), findsOneWidget);
    }
  });

  testWidgets('a delivery-only role is offered no other kind of sale', (t) async {
    deliveryDeskOnly();
    draftOnTheTill(type: OrderType.delivery);
    await t.pumpWidget(app());
    await signIn(t);

    expect(find.byKey(const Key('order-type-delivery')), findsOneWidget);
    expect(find.byKey(const Key('order-type-dinein')), findsNothing);
    expect(find.byKey(const Key('order-type-takeaway')), findsNothing);
  });

  testWidgets('the sale already in hand keeps its own chip, whatever the role',
      (t) async {
    deliveryDeskOnly();
    // Handed over mid-service: it must stay settleable on this till.
    draftOnTheTill(type: OrderType.dineIn);
    await t.pumpWidget(app());
    await signIn(t);

    expect(find.byKey(const Key('order-type-dinein')), findsOneWidget);
    expect(find.byKey(const Key('order-type-takeaway')), findsNothing);
  });

  testWidgets('the floor drops the buttons for the types the role cannot ring',
      (t) async {
    settings.setRoleOrderType('cashier', OrderType.delivery, false);
    await t.pumpWidget(app());
    // No draft, so sign-in lands on the floor.
    await signIn(t);
    await t.pumpAndSettle();

    expect(find.byType(TableFloorScreen), findsOneWidget);
    expect(find.byKey(const Key('floor-takeaway')), findsOneWidget);
    expect(find.byKey(const Key('floor-delivery')), findsNothing);
  });

  testWidgets('tapping a table says no rather than opening a sale the role cannot',
      (t) async {
    deliveryDeskOnly();
    await t.pumpWidget(app());
    await signIn(t);
    await t.pumpAndSettle();

    await t.tap(find.byKey(Key('table-tile-${table5.id}')));
    await t.pumpAndSettle();

    expect(find.text('This role does not open dine-in orders.'), findsOneWidget);
    expect(orders.held(), isEmpty);
  });
}
