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
import 'package:offline_pos/features/reports/cost_sales_report_screen.dart';
import 'package:offline_pos/features/reports/menu_engineering_report_screen.dart';
import 'package:offline_pos/features/sell/sell_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// The margin reports as a manager reaches them: through the drawer of a running
/// app, on costs that came down with the menu.
///
/// The maths is covered by the screen tests. What is covered here is the seam: the
/// costs live in a catalogue column the hub cannot read for itself, so if the shell
/// stops passing them both screens quietly report that nothing was ever costed.
void main() {
  late Db db;
  late OrderStore orders;
  late SettingsStore settings;
  late AuditLog audit;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    orders = OrderStore(db);
    settings = SettingsStore(db);
    audit = AuditLog(db);
    await AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'sara', name: 'Sara', pin: '1234');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');
  });
  tearDown(() => db.close());

  /// A menu with a cost on the pizza and none on the water, which is what a shop
  /// that has costed half its products looks like.
  void seedMenu() => CatalogueStore(db).replaceAll(
        categories: const [Category(id: 1, name: 'Food')],
        products: const [
          Product(id: 1, name: 'Pizza', price: 100, categoryId: 1, cost: 40),
          Product(id: 2, name: 'Water', price: 20, categoryId: 1),
        ],
        groups: const [],
        productGroupIds: const {},
        refreshedAt: DateTime.now().toUtc(),
      );

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

  Order sale(int productId, String name, double amount,
      {OrderState state = OrderState.paid, double qty = 1}) {
    final order = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      type: OrderType.takeaway,
      state: state,
    )..lines.add(OrderLine(
        productId: productId, name: name, quantity: qty, unitPrice: amount));
    orders.save(order, announce: false);
    return order;
  }

  /// An order being rung keeps sign-in on the sell screen instead of opening the
  /// floor, which is where the navigation drawer lives.
  void draftOnTheTill() => sale(1, 'Pizza', 10, state: OrderState.draft);

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

  Future<void> openReport(WidgetTester t, String tile) async {
    t.state<ScaffoldState>(find
            .descendant(of: find.byType(SellScreen), matching: find.byType(Scaffold))
            .first)
        .openDrawer();
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-report')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('range-all')));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.byKey(Key(tile)), 200,
        scrollable: find.byType(Scrollable).last);
    await t.tap(find.byKey(Key(tile)));
    await t.pumpAndSettle();
  }

  void tallWindow(WidgetTester t) {
    t.view.physicalSize = const Size(1000, 3200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

  testWidgets('cost vs sales reads the costs the menu brought down', (t) async {
    tallWindow(t);
    seedMenu();
    draftOnTheTill();
    sale(1, 'Pizza', 100, qty: 2);
    sale(2, 'Water', 20);

    await t.pumpWidget(app());
    await signIn(t);
    await openReport(t, 'rep-cost');

    expect(find.byType(CostSalesReportScreen), findsOneWidget);
    expect(find.byKey(const Key('cost-empty-state')), findsNothing,
        reason: 'the shell must hand the hub the costs, or the report is dead');
    // Two pizzas at 100 cost 40 each: 200 in, 80 out, 120 kept. The draft on the
    // till is not a sale and the uncosted water stays out of the totals.
    expect(find.byKey(const Key('cost-product-1')), findsOneWidget);
    expect(find.text('120.00'), findsWidgets);
    expect(find.byKey(const Key('cost-not-costed')), findsOneWidget);
  });

  testWidgets('menu engineering places the dishes the till actually sold',
      (t) async {
    tallWindow(t);
    seedMenu();
    draftOnTheTill();
    sale(1, 'Pizza', 100, qty: 5);

    await t.pumpWidget(app());
    await signIn(t);
    await openReport(t, 'rep-menu');

    expect(find.byType(MenuEngineeringReportScreen), findsOneWidget);
    expect(find.byKey(const Key('menu-empty-state')), findsNothing);
    expect(find.byKey(const Key('menu-item-1')), findsOneWidget);
  });

  testWidgets('a till whose Odoo states no costs says so instead of guessing',
      (t) async {
    tallWindow(t);
    CatalogueStore(db).replaceAll(
      categories: const [Category(id: 1, name: 'Food')],
      products: const [Product(id: 1, name: 'Pizza', price: 100, categoryId: 1)],
      groups: const [],
      productGroupIds: const {},
      refreshedAt: DateTime.now().toUtc(),
    );
    draftOnTheTill();
    sale(1, 'Pizza', 100);

    await t.pumpWidget(app());
    await signIn(t);
    await openReport(t, 'rep-cost');

    expect(find.byKey(const Key('cost-empty-state')), findsOneWidget);
  });
}
