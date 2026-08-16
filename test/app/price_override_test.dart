import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/app/pos_app.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/auth/auth_service.dart';
import 'package:offline_pos/core/auth/permissions.dart';
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
import 'package:offline_pos/features/sell/sell_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// The price a cashier can type, and the 86 board they can flip: two different
/// decisions that used to share one permission labelled after neither of them.
void main() {
  late Db db;
  late OrderStore orders;
  late SettingsStore settings;
  late AuditLog audit;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    // The till refuses to start an order with no shift open, so a test that
    // sells opens the drawer first.
    ShiftStore(db).openShift(openingFloat: 100, cashierId: 'sara');
    orders = OrderStore(db);
    settings = SettingsStore(db);
    audit = AuditLog(db);
    CatalogueStore(db).replaceAll(
      categories: const [Category(id: 1, name: 'Pizza')],
      products: const [Product(id: 10, name: 'Margherita', price: 250, categoryId: 1)],
      groups: const [],
      productGroupIds: const {},
      refreshedAt: DateTime.now().toUtc(),
    );
    final auth =
        AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit);
    await auth.enrol(id: 'sara', name: 'Sara', pin: '1234');
    await auth.enrol(id: 'mo', name: 'Mo', pin: '9999', role: 'manager');
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
      tables: TableStore(db),
      settings: settings,
      customers: CustomerStore(db),
      attendance: AttendanceStore(db),
      config: const TillConfig(),
    );
  }

  Order draftOnTheTill() {
    final order =
        Order(deviceId: 'till-1', cashierId: 'sara', type: OrderType.takeaway)
          ..lines.add(OrderLine(
              productId: 10, name: 'Margherita', quantity: 2, unitPrice: 250));
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

  Future<void> openLineActions(WidgetTester t, Order order) async {
    await t.tap(find.byKey(Key('line-${order.lines.first.uuid}')));
    await t.pumpAndSettle();
  }

  testWidgets('a granted cashier can sell a line at another price, and it is recorded',
      (t) async {
    settings.setRolePermission('cashier', Permission.priceOverride, true);
    final order = draftOnTheTill();

    await t.pumpWidget(app());
    await signIn(t);
    await openLineActions(t, order);
    await t.tap(find.byKey(const Key('line-price')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('line-price-value')), '180');
    await t.tap(find.byKey(const Key('apply-line-price')));
    await t.pumpAndSettle();

    // On screen and on disk: two at 180, not two at 250.
    expect(find.byKey(const Key('total')), findsOneWidget);
    await t.tap(find.byKey(const Key('hold')));
    await t.pumpAndSettle();
    final held = orders.held().single;
    expect(held.lines.single.unitPrice, 180);
    expect(held.total, 360);

    final entry = audit.recent(event: 'line.price_override').single;
    expect(entry['detail'], contains('Margherita|250.0|180.0'),
        reason: 'what it was and what it became, or the money is untraceable');
  });

  testWidgets('without the grant the price takes a manager', (t) async {
    final order = draftOnTheTill();

    await t.pumpWidget(app());
    await signIn(t);
    await openLineActions(t, order);
    await t.tap(find.byKey(const Key('line-price')));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('manager-pin')), findsOneWidget);
    await t.enterText(find.byKey(const Key('manager-pin')), '9999');
    await t.tap(find.byKey(const Key('manager-ok')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('line-price-value')), findsOneWidget);
  });

  testWidgets('the 86 board asks for the availability grant, not the price one',
      (t) async {
    // A cashier trusted with prices is not automatically trusted with the menu.
    settings.setRolePermission('cashier', Permission.priceOverride, true);
    draftOnTheTill();

    await t.pumpWidget(app());
    await signIn(t);
    await t.longPress(find.byKey(const Key('product-10')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('menu-86')));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('manager-pin')), findsOneWidget,
        reason: 'the 86 menu is gated on availability, which this role lacks');
  });

  testWidgets('a cashier granted availability can 86 an item on their own',
      (t) async {
    settings.setRolePermission('cashier', Permission.itemAvailability, true);
    draftOnTheTill();

    await t.pumpWidget(app());
    await signIn(t);
    await t.longPress(find.byKey(const Key('product-10')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('menu-86')));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('manager-pin')), findsNothing);
    expect(settings.unavailableProducts, contains(10));
    expect(find.byKey(const Key('soldout-10')), findsOneWidget);
  });
}
