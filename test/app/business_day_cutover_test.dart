import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/app/pos_app.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/auth/auth_service.dart';
import 'package:offline_pos/core/auth/user_store.dart';
import 'package:offline_pos/core/config/till_config.dart';
import 'package:offline_pos/core/db/attendance_store.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/domain/catalogue.dart';
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
import 'package:offline_pos/domain/business_day.dart';
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

/// The shop's trading-day rule as it actually reaches a sale.
///
/// The boundary maths is covered in the domain test. What is covered here is the
/// seam that was missing: the hour is configurable, and a bill rung on a running
/// app is stamped with it, so a 2am sale lands on the night that produced it
/// rather than on tomorrow's report.
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
    CatalogueStore(db).replaceAll(
      categories: const [Category(id: 1, name: 'Food')],
      products: const [Product(id: 10, name: 'Pizza', price: 100, categoryId: 1)],
      groups: const [],
      productGroupIds: const {},
      paymentMethods: const [PaymentMethod(id: 1, name: 'Cash', isCash: true)],
      refreshedAt: DateTime.now().toUtc(),
    );
    await AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'sara', name: 'Sara', pin: '1234');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');
  });
  tearDown(() {
    db.close();
    // A published shop rule outlives the database it came from, so put it back for
    // whatever runs next in this file.
    BusinessDay.shopCutoverHour = BusinessDay.defaultCutoverHour;
  });

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

  void draftOnTheTill() {
    final order = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      type: OrderType.dineIn,
      tableLabel: '5',
    )..lines.add(OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 100));
    orders.save(order, announce: false);
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

  testWidgets('a bill rung on the app carries the shop cutover hour', (t) async {
    settings.businessDayCutoverHour = 5;

    await t.pumpWidget(app());
    await signIn(t);
    // Nothing on the till, so the shell lands on the floor. Start a takeaway there
    // the way a cashier does, ring one item, and park it.
    await t.tap(find.byKey(const Key('floor-takeaway')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('product-10')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('hold')));
    await t.pumpAndSettle();

    final held = orders.held().single;
    expect(held.businessDayCutoverHour, 5,
        reason: 'the setting must reach an order created by the running app');
    // A sale at 03:00 under a 05:00 cutover belongs to the night before.
    final night = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      createdAt: DateTime(2026, 3, 11, 3),
    );
    expect(night.businessDayCutoverHour, 5);
    expect(night.businessDay.key, '2026-03-10');
    expect(night.toMap()['business_date'], '2026-03-10');
  });

  testWidgets('the rule survives a restart and never grows the wire payload',
      (t) async {
    settings.businessDayCutoverHour = 5;
    draftOnTheTill();

    await t.pumpWidget(app());
    await signIn(t);
    await t.tap(find.byKey(const Key('hold')));
    await t.pumpAndSettle();
    final uuid = orders.held().single.uuid;

    // The next launch reads the setting back off disk and republishes it, so the
    // rule is not something only this session knew.
    BusinessDay.shopCutoverHour = BusinessDay.defaultCutoverHour;
    SettingsStore(db);
    expect(BusinessDay.shopCutoverHour, 5);

    final reloaded = OrderStore(db).byUuid(uuid)!;
    expect(reloaded.businessDayCutoverHour, 5);
    expect(reloaded.toServerPayload().containsKey('business_day_cutover_hour'), isFalse,
        reason: 'the rule is local; the server is handed the date it produced');
    expect(reloaded.toServerPayload()['business_date'], isNotNull);
  });

  testWidgets('a till that never configures a cutover keeps trading as it did',
      (t) async {
    draftOnTheTill();

    await t.pumpWidget(app());
    await signIn(t);
    await t.tap(find.byKey(const Key('hold')));
    await t.pumpAndSettle();

    expect(orders.held().single.businessDayCutoverHour,
        BusinessDay.defaultCutoverHour);
  });
}
