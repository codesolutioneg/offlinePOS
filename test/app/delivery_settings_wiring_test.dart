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
import 'package:offline_pos/core/db/delivery_store.dart';
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
import 'package:offline_pos/features/settings/delivery_settings_screen.dart';
import 'package:offline_pos/features/tables/table_floor_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// The delivery lists, edited where a manager would actually find them: through the
/// settings hub of a running till, and then used on the very next order.
void main() {
  late Db db;
  late OrderStore orders;
  late DeliveryStore delivery;
  late AuditLog audit;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    orders = OrderStore(db, ownDeviceId: 'till-1');
    delivery = DeliveryStore(db);
    audit = AuditLog(db);
    CatalogueStore(db).replaceAll(
      categories: const [Category(id: 1, name: 'Food')],
      products: const [Product(id: 10, name: 'Pizza', price: 100, categoryId: 1)],
      groups: const [],
      productGroupIds: const {},
      customers: const [Customer(id: 77, name: 'Talabat Egypt')],
      refreshedAt: DateTime.now().toUtc(),
    );
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
      settings: SettingsStore(db),
      customers: CustomerStore(db),
      delivery: delivery,
      attendance: AttendanceStore(db),
      config: const TillConfig(),
    );
  }

  Future<void> signIn(WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => t.binding.setSurfaceSize(null));
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
    // Signing in lands on the floor home, which carries the same drawer the
    // counter does, so the settings hub is reached from here without opening an
    // order first.
    expect(find.byType(TableFloorScreen), findsOneWidget);
  }

  Future<void> openDeliverySettings(WidgetTester t) async {
    await t.tap(find.byType(DrawerButton));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-settings')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('set-delivery')));
    await t.pumpAndSettle();
    expect(find.byType(DeliverySettingsScreen), findsOneWidget,
        reason: 'the hub must reach the screen, or the lists cannot be edited');
  }

  testWidgets('a manager adds a zone through the hub', (t) async {
    await signIn(t);
    await openDeliverySettings(t);

    await t.tap(find.byKey(const Key('add-zone')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('zone-name')), 'Maadi');
    await t.enterText(find.byKey(const Key('zone-fee')), '25');
    await t.tap(find.byKey(const Key('save-zone')));
    await t.pumpAndSettle();

    final zone = delivery.zones().single;
    expect(zone.name, 'Maadi');
    expect(zone.fee, 25);
    expect(find.byKey(Key('zone-${zone.id}')), findsOneWidget);
  });

  testWidgets('a zone fee can be corrected and a zone removed', (t) async {
    final zone = delivery.addZone(name: 'Maadi', fee: 25);
    await signIn(t);
    await openDeliverySettings(t);

    await t.tap(find.byKey(Key('edit-zone-${zone.id}')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('zone-fee')), '30');
    await t.tap(find.byKey(const Key('save-zone')));
    await t.pumpAndSettle();
    expect(delivery.zones().single.fee, 30);

    await t.tap(find.byKey(Key('delete-zone-${zone.id}')));
    await t.pumpAndSettle();
    expect(delivery.zones(), isEmpty);
    expect(find.byKey(const Key('no-zones')), findsOneWidget);
  });

  testWidgets('a channel can be pointed at the partner it is invoiced to', (t) async {
    await signIn(t);
    await openDeliverySettings(t);
    await t.tap(find.byKey(const Key('tab-channels')));
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('add-channel')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('channel-name')), 'Talabat');
    await t.tap(find.byKey(const Key('channel-partner')));
    await t.pumpAndSettle();
    await t.tap(find.text('Talabat Egypt').last);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('save-channel')));
    await t.pumpAndSettle();

    final channel = delivery.channels().single;
    expect(channel.name, 'Talabat');
    expect(channel.partnerId, 77);
  });

  testWidgets('a driver is added and can be switched off when they leave', (t) async {
    await signIn(t);
    await openDeliverySettings(t);
    await t.tap(find.byKey(const Key('tab-drivers')));
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('add-driver')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('driver-name')), 'Hany');
    await t.enterText(find.byKey(const Key('driver-phone')), '0100');
    await t.tap(find.byKey(const Key('save-driver')));
    await t.pumpAndSettle();
    expect(delivery.drivers(activeOnly: true).single.name, 'Hany');

    final driver = delivery.drivers().single;
    await t.tap(find.byKey(Key('driver-${driver.id}')));
    await t.pumpAndSettle();
    expect(delivery.drivers(activeOnly: true), isEmpty);
    expect(delivery.drivers().single.active, isFalse,
        reason: 'a driver who left keeps the orders they carried');
  });
}
