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
import 'package:offline_pos/core/onboarding/wizard_store.dart';
import 'package:offline_pos/core/printing/printer_discovery.dart';
import 'package:offline_pos/core/printing/printer_registry.dart';
import 'package:offline_pos/core/sync/odoo_endpoint.dart';
import 'package:offline_pos/core/sync/odoo_wiring.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/core/sync/sync_service.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/auth/login_screen.dart';
import 'package:offline_pos/features/kitchen/kitchen_display_screen.dart';
import 'package:offline_pos/features/sell/sell_screen.dart';
import 'package:offline_pos/features/settings/lan_settings_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

/// Nothing answers a sweep. A kitchen screen has no printer of its own, and a
/// discovery that reached for the network would be the one thing in this test that
/// could hang.
class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

void main() {
  late Db db;
  late OrderStore orders;
  late List<LanEventKind> published;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    published = [];
    // A kitchen screen books nothing of its own, so every ticket it shows arrived
    // from a till over the fabric, and every bump goes back the same way.
    orders = OrderStore(
      db,
      ownDeviceId: 'kds-1',
      publish: (kind, uuid, payload) => published.add(kind),
    );
  });
  tearDown(() => db.close());

  /// The app as a KDS build launches it: no cashier signed in, no shift open.
  Widget app({bool kdsMode = true}) {
    final outbox = Outbox(store: SqliteOutboxStore(db), senders: {});
    return PosApp(
      auth: AuthService(
          users: UserStore(db), hasher: FakePinHasher(), audit: AuditLog(db)),
      users: UserStore(db),
      catalogue: CatalogueStore(db),
      orders: orders,
      outbox: outbox,
      audit: AuditLog(db),
      // Never started: a board does not sync, and the till that took the money is
      // the only device that pushes it.
      sync: SyncService(
        outbox: outbox,
        catalogue: CatalogueStore(db),
        outboxStore: SqliteOutboxStore(db),
        deviceId: 'kds-1',
        appVersion: 'test',
      ),
      outboxStore: SqliteOutboxStore(db),
      printers: PrinterRegistry(discovery: _NoPrinters()),
      wizards: WizardStore(db),
      shifts: ShiftStore(db),
      deviceId: 'kds-1',
      endpoints: OdooEndpointStore(db),
      odoo: OdooWiring(outbox: outbox),
      tables: TableStore(db),
      settings: SettingsStore(db),
      customers: CustomerStore(db),
      attendance: AttendanceStore(db),
      config: TillConfig(kdsMode: kdsMode),
    );
  }

  /// A ticket rung on a till and replicated here, which is the only way an order
  /// ever reaches a kitchen screen.
  Order fromTheTill({String table = '5'}) {
    final order = Order(deviceId: 'till-a', cashierId: 'ana', tableLabel: table)
      ..state = OrderState.held
      ..lines.add(OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 100));
    orders.save(order, announce: false);
    return order;
  }

  testWidgets('a KDS build boots straight into the board, with nobody signed in',
      (t) async {
    final order = fromTheTill();
    await t.pumpWidget(app());

    expect(find.byType(KitchenDisplayScreen), findsOneWidget);
    expect(find.byKey(Key('kds-${order.uuid}')), findsOneWidget);
    // No sign-in to get past and no selling surface to get at.
    expect(find.byType(LoginScreen), findsNothing);
    expect(find.byType(SellScreen), findsNothing);
    // And no shift was needed to see any of it.
    expect(ShiftStore(db).currentOpenShift(), isNull);
  });

  testWidgets('the same build without the flag still asks who is on the till',
      (t) async {
    await t.pumpWidget(app(kdsMode: false));

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(KitchenDisplayScreen), findsNothing);
  });

  testWidgets('a bump on the board goes back as a kitchen status, not as a sale',
      (t) async {
    final order = fromTheTill();
    await t.pumpWidget(app());

    await t.tap(find.byKey(Key('kds-${order.uuid}-start')));
    await t.pump();

    expect(orders.byUuid(order.uuid)!.kitchenStatus, KitchenStatus.preparing);
    // A status event, which is what lets a screen advance a ticket it does not own.
    // Anything else would have this device claiming another till's sale.
    expect(published, [LanEventKind.kitchenStatus]);
    expect(orders.byUuid(order.uuid)!.deviceId, 'till-a');
    expect(SqliteOutboxStore(db).pendingCount, 0);
  });

  testWidgets('the board has a door to the shop network settings', (t) async {
    await t.pumpWidget(app());

    // A wall-mounted screen has no drawer and never sees the sign-in screen, so
    // this is the only way to name it or read its device id back to support.
    await t.tap(find.byKey(const Key('kds-network')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));

    expect(find.byType(LanSettingsScreen), findsOneWidget);
    // Below the switches on a screen this short, so scroll to it rather than
    // assert on whatever happens to fit the viewport.
    await t.dragUntilVisible(find.byKey(const Key('lan-device-id')),
        find.byType(ListView), const Offset(0, -120));
    expect(find.text('kds-1'), findsOneWidget);
  });
}
