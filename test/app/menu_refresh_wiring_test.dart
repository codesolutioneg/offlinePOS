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
import 'package:offline_pos/core/sync/odoo_puller.dart';
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

/// A price changed in Odoo, as the till actually learns about it.
///
/// The gate that made this a six-hour wait is covered in the service's own tests.
/// What is covered here is the seam: the app shell has to ASK for the menu when a
/// cashier signs in and when a manager taps Refresh menu, or the force flag is a
/// setting nothing reads.
void main() {
  late Db db;
  late OrderStore orders;
  late SettingsStore settings;
  late AuditLog audit;
  late int pulls;
  late double price;
  late bool serverUp;
  late int drained;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    orders = OrderStore(db);
    settings = SettingsStore(db);
    audit = AuditLog(db);
    pulls = 0;
    price = 10;
    serverUp = true;
    drained = 0;
    await AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'sara', name: 'Sara', pin: '1234', role: 'manager');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');
  });
  tearDown(() => db.close());

  /// A server that hands down one product at whatever [price] currently is, so a
  /// test can change it the way a manager changes it in Odoo.
  OdooPuller puller() => OdooPuller(
        call: (model, method, args, kwargs) async {
          if (!serverUp) throw Exception('no route to host');
          if (model != 'product.product') return const [];
          pulls++;
          return [
            {
              'id': 1,
              'display_name': 'Pizza',
              'lst_price': price,
              'pos_categ_ids': const <int>[],
              'active': true,
            }
          ];
        },
      );

  Widget app() {
    // A sender that counts, so the test can prove a menu pull never turns into a
    // push of the day's takings.
    final outbox = Outbox(
      store: SqliteOutboxStore(db),
      senders: {'order.push': (e) async => drained++},
    );
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
        puller: puller(),
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

  /// An order being rung keeps sign-in on the sell screen instead of opening the
  /// floor, which is where the navigation drawer lives.
  void draftOnTheTill() {
    final order = Order(deviceId: 'till-1', cashierId: 'sara')
      ..lines.add(OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 10));
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

  /// The drawer is a long list and the settings row sits near its foot, so the
  /// window has to be tall enough to reach it without scrolling.
  void tallWindow(WidgetTester t) {
    t.view.physicalSize = const Size(1000, 2400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

  Future<void> openSettingsHub(WidgetTester t) async {
    t.state<ScaffoldState>(find
            .descendant(of: find.byType(SellScreen), matching: find.byType(Scaffold))
            .first)
        .openDrawer();
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-settings')));
    await t.pumpAndSettle();
  }

  testWidgets('signing in pulls the menu instead of waiting for the age gate',
      (t) async {
    draftOnTheTill();
    await t.pumpWidget(app());
    expect(pulls, 0, reason: 'nobody has signed in yet');

    await signIn(t);
    await t.pumpAndSettle();

    expect(pulls, 1, reason: 'the shell must ask for the menu at sign-in');
    expect(CatalogueStore(db).products().single.price, 10);
  });

  testWidgets('Refresh menu brings a new price down there and then', (t) async {
    tallWindow(t);
    draftOnTheTill();
    await t.pumpWidget(app());
    await signIn(t);
    await t.pumpAndSettle();
    expect(pulls, 1);

    // The manager changed the price in Odoo a minute ago. The catalogue on the
    // till is minutes old, so the ordinary six-hour gate would hold it back.
    price = 14;
    await openSettingsHub(t);
    await t.tap(find.byKey(const Key('set-refresh-menu')));
    await t.pumpAndSettle();

    expect(pulls, 2, reason: 'the manual action must bypass the age gate');
    expect(CatalogueStore(db).products().single.price, 14);
    expect(find.byKey(const Key('menu-refresh-result')), findsOneWidget);
    expect(find.text('Menu and prices updated.'), findsOneWidget);
  });

  testWidgets('Refresh menu with the line down keeps the prices and says so',
      (t) async {
    tallWindow(t);
    draftOnTheTill();
    await t.pumpWidget(app());
    await signIn(t);
    await t.pumpAndSettle();
    expect(CatalogueStore(db).products().single.price, 10);

    serverUp = false;
    await openSettingsHub(t);
    await t.tap(find.byKey(const Key('set-refresh-menu')));
    await t.pumpAndSettle();

    expect(CatalogueStore(db).products().single.price, 10,
        reason: 'a failed pull must never wipe what the till is selling from');
    expect(find.byKey(const Key('menu-refresh-result')), findsOneWidget);
  });

  testWidgets('a menu refresh never pushes the day off the till', (t) async {
    tallWindow(t);
    draftOnTheTill();
    // A paid sale queued for the shift-close batch.
    await Outbox(store: SqliteOutboxStore(db), senders: {})
        .enqueue('order.push', 'u1', {'uuid': 'u1'});

    await t.pumpWidget(app());
    await signIn(t);
    await t.pumpAndSettle();
    await openSettingsHub(t);
    await t.tap(find.byKey(const Key('set-refresh-menu')));
    await t.pumpAndSettle();

    expect(drained, 0, reason: 'orders leave the till as one batch at shift close');
    expect(SqliteOutboxStore(db).pendingSalesCount, 1);
  });
}
