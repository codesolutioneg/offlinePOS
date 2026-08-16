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
import 'package:offline_pos/core/lan/lan_event.dart';
import 'package:offline_pos/core/onboarding/wizard_id.dart';
import 'package:offline_pos/core/onboarding/wizard_store.dart';
import 'package:offline_pos/core/printing/printer_discovery.dart';
import 'package:offline_pos/core/printing/printer_registry.dart';
import 'package:offline_pos/core/sync/odoo_endpoint.dart';
import 'package:offline_pos/core/sync/odoo_wiring.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/core/sync/sync_service.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/features/sell/sell_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// The 86 board as the shop gets it: a cashier marks an item off on a real app
/// shell, and what leaves the till is a fabric event the other devices can apply.
///
/// The replication itself is proven in test/lan/lan_availability_test.dart. What is
/// proven here is the seam nobody notices is missing: a setting that no running app
/// ever announces makes every unit test pass and still leaves the second till
/// selling food the kitchen has run out of.
void main() {
  late Db db;
  late SettingsStore settings;
  late AuditLog audit;
  late List<({LanEventKind kind, String uuid, Map<String, dynamic> payload})> sent;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    // The till refuses to start an order with no shift open, so a test that
    // sells opens the drawer first.
    ShiftStore(db).openShift(openingFloat: 100, cashierId: 'sara');
    settings = SettingsStore(db);
    audit = AuditLog(db);
    sent = [];
    settings.publish =
        (kind, uuid, payload) => sent.add((kind: kind, uuid: uuid, payload: payload));
    CatalogueStore(db).replaceAll(
      categories: const [Category(id: 1, name: 'Food')],
      products: const [Product(id: 10, name: 'Pizza', price: 250, categoryId: 1)],
      groups: const [],
      productGroupIds: const {},
      refreshedAt: DateTime.now().toUtc(),
    );
    // A manager, so the 86 gate passes without a PIN dialog standing between this
    // test and the wiring it is about.
    await AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'sara', name: 'Sara', pin: '1234', role: 'manager');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');
  });
  tearDown(() => db.close());

  Widget app() {
    final outbox = Outbox(store: SqliteOutboxStore(db), senders: {});
    return PosApp(
      auth: AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit),
      users: UserStore(db),
      catalogue: CatalogueStore(db),
      orders: OrderStore(db, ownDeviceId: 'till-1'),
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

  testWidgets('marking an item sold out on the till announces it to the shop',
      (t) async {
    await t.pumpWidget(app());
    await signIn(t);
    // Back to the counter: sign-in lands on the floor plan.
    await t.tap(find.byKey(const Key('floor-takeaway')));
    await t.pumpAndSettle();

    await t.longPress(find.byKey(const Key('product-10')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('menu-86')));
    await t.pumpAndSettle();

    expect(settings.unavailableProducts, {10});
    expect(sent, hasLength(1),
        reason: 'the shell must announce the 86, or the other till keeps selling it');
    expect(sent.single.kind, LanEventKind.productAvailability);
    expect(sent.single.uuid, SettingsStore.availabilityRecord(10));
    expect(sent.single.payload, {'product_id': 10, 'available': false});
  });

  testWidgets('an item another till marked off cannot be rung here', (t) async {
    await t.pumpWidget(app());
    await signIn(t);
    await t.tap(find.byKey(const Key('floor-takeaway')));
    await t.pumpAndSettle();

    // What the applier does with a peer's event, arriving while the counter is open.
    settings.applyProductAvailable(10, false);
    // The same slow lane the spool flush runs in, which is what repaints the grid.
    await t.pump(const Duration(seconds: 31));
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('product-10')));
    await t.pumpAndSettle();
    expect(find.text('Pizza: sold out'), findsOneWidget);
    // Applying a peer's event announces nothing: the origin told everybody already.
    expect(sent, isEmpty);
  });
}
