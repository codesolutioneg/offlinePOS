import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/app/pos_app.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/auth/auth_service.dart';
import 'package:offline_pos/core/auth/bootstrap_cashier.dart';
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

/// The half-finished install, as the person doing it actually meets it.
///
/// A till with no server, no menu, no printer and no roster sells perfectly well,
/// which is why nothing ever complained. These cover the two places that now do:
/// the walkthrough the provisioning account gets, and the checklist above the
/// settings it is asking for.
void main() {
  late Db db;
  late OrderStore orders;
  late SettingsStore settings;
  late UserStore users;
  late AuditLog audit;
  late PrinterRegistry printers;
  late WizardStore wizards;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    orders = OrderStore(db);
    settings = SettingsStore(db);
    users = UserStore(db);
    audit = AuditLog(db);
    printers = PrinterRegistry(discovery: _NoPrinters());
    wizards = WizardStore(db);
  });
  tearDown(() => db.close());

  AuthService authService() =>
      AuthService(users: users, hasher: FakePinHasher(), audit: audit);

  /// The account a freshly installed till comes up on, and nothing else.
  Future<void> onlyTheSetupAccount() async {
    await authService().enrol(
        id: BootstrapCashier.id, name: BootstrapCashier.name, pin: '1234', role: 'manager');
  }

  Future<void> aRealManager() async {
    await authService().enrol(id: 'sara', name: 'Sara', pin: '1234', role: 'manager');
    wizards.dismiss(WizardId.firstSale, 'sara');
  }

  Widget app() {
    final outbox = Outbox(store: SqliteOutboxStore(db), senders: {});
    return PosApp(
      auth: authService(),
      users: users,
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
      printers: printers,
      wizards: wizards,
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

  void draftOnTheTill(String cashierId) {
    final order = Order(deviceId: 'till-1', cashierId: cashierId)
      ..lines.add(OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 10));
    orders.save(order, announce: false);
  }

  void tallWindow(WidgetTester t) {
    t.view.physicalSize = const Size(1000, 3200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

  Future<void> signIn(WidgetTester t, String userKey) async {
    await t.tap(find.byKey(Key('user-$userKey')));
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

  Future<void> openSettingsHub(WidgetTester t) async {
    t.state<ScaffoldState>(find
            .descendant(of: find.byType(SellScreen), matching: find.byType(Scaffold))
            .first)
        .openDrawer();
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-settings')));
    await t.pumpAndSettle();
  }

  /// A till whose setup was actually finished.
  void finishTheSetup() {
    OdooEndpointStore(db).save(const OdooEndpoint(
        baseUrl: 'https://shop.example', db: 'shop', login: 'till', password: 'x'));
    CatalogueStore(db).replaceAll(
      categories: const [],
      products: const [Product(id: 1, name: 'Pizza', price: 10)],
      groups: const [],
      productGroupIds: const {},
      refreshedAt: DateTime.now().toUtc(),
    );
    printers.remember(PosApp.receiptPrinter, host: '10.0.0.9');
  }

  testWidgets('the provisioning account is walked through what is left to do',
      (t) async {
    await onlyTheSetupAccount();
    draftOnTheTill(BootstrapCashier.id);

    await t.pumpWidget(app());
    await signIn(t, BootstrapCashier.id);

    expect(find.byKey(const Key('wizard-progress')), findsOneWidget,
        reason: 'the first-sign-in wizard was never mounted before this');
    // Read to the last panel, which names what this till is actually missing.
    await t.tap(find.byKey(const Key('wizard-next')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('wizard-next')));
    await t.pumpAndSettle();
    expect(find.textContaining('Point the till at your server'), findsOneWidget);
    expect(find.textContaining('Add your staff'), findsOneWidget);
  });

  testWidgets('an ordinary cashier never meets the setup walkthrough', (t) async {
    await aRealManager();
    draftOnTheTill('sara');

    await t.pumpWidget(app());
    await signIn(t, 'sara');

    expect(find.byKey(const Key('wizard-progress')), findsNothing);
  });

  testWidgets('the settings hub carries the checklist until the till is set up',
      (t) async {
    tallWindow(t);
    await aRealManager();
    draftOnTheTill('sara');

    await t.pumpWidget(app());
    await signIn(t, 'sara');
    await openSettingsHub(t);

    expect(find.byKey(const Key('setup-checklist')), findsOneWidget);
    expect(find.byKey(const Key('setup-step-server')), findsOneWidget);
    expect(find.byKey(const Key('setup-step-menu')), findsOneWidget);
    expect(find.byKey(const Key('setup-step-printer')), findsOneWidget);
    expect(find.byKey(const Key('setup-step-staff')), findsOneWidget);
  });

  testWidgets('a till that is set up shows no checklist, and never will again',
      (t) async {
    tallWindow(t);
    await aRealManager();
    draftOnTheTill('sara');
    finishTheSetup();

    await t.pumpWidget(app());
    await signIn(t, 'sara');
    await openSettingsHub(t);

    expect(find.byKey(const Key('setup-checklist')), findsNothing);
    // Recorded as done, so unplugging a printer next winter cannot bring an
    // onboarding card back over a working shop.
    expect(wizards.shouldShow(WizardId.setupChecklist, 'sara'), isFalse);
  });

  testWidgets('hiding the checklist keeps it hidden', (t) async {
    tallWindow(t);
    await aRealManager();
    draftOnTheTill('sara');

    await t.pumpWidget(app());
    await signIn(t, 'sara');
    await openSettingsHub(t);
    await t.tap(find.byKey(const Key('setup-checklist-hide')));
    await t.pumpAndSettle();

    await openSettingsHub(t);
    expect(find.byKey(const Key('setup-checklist')), findsNothing);
  });
}
