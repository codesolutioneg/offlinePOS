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

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// The service charge as the shop actually gets it: configured in settings, and
/// reaching an order rung on a real app shell.
///
/// The domain maths is covered elsewhere. What is covered here is the seam: the
/// session takes the percentage from an injected resolver, and nothing charges
/// anybody if the shell forgets to hand it over.
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
    final order = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      type: OrderType.dineIn,
      tableLabel: '5',
    )..lines.add(OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 100));
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

  testWidgets('an order rung on the app carries the configured service charge',
      (t) async {
    settings.serviceChargePercent = 12;
    settings.setServiceChargeOrderType(OrderType.dineIn, true);
    draftOnTheTill();

    await t.pumpWidget(app());
    await signIn(t);
    // Re-picking the type is the moment the session stamps the bill, and it is the
    // shell's resolver that decides what gets stamped.
    await t.tap(find.byKey(const Key('order-type-dinein')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('hold')));
    await t.pumpAndSettle();

    final held = orders.held().single;
    expect(held.serviceChargePercent, 12,
        reason: 'the shell must hand the session a resolver, or nobody is ever charged');
    expect(held.total, 112);
  });

  testWidgets('a type the shop does not charge for is left alone', (t) async {
    settings.serviceChargePercent = 12;
    settings.setServiceChargeOrderType(OrderType.dineIn, true);
    settings.setServiceChargeOrderType(OrderType.takeaway, false);
    draftOnTheTill();

    await t.pumpWidget(app());
    await signIn(t);
    await t.tap(find.byKey(const Key('order-type-takeaway')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('hold')));
    await t.pumpAndSettle();

    final held = orders.held().single;
    expect(held.serviceChargePercent, 0);
    expect(held.total, 100);
  });

  testWidgets('with no service charge configured a bill is exactly what it was',
      (t) async {
    draftOnTheTill();

    await t.pumpWidget(app());
    await signIn(t);
    await t.tap(find.byKey(const Key('order-type-dinein')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('hold')));
    await t.pumpAndSettle();

    expect(orders.held().single.serviceChargePercent, 0);
    expect(orders.held().single.total, 100);
  });
}
