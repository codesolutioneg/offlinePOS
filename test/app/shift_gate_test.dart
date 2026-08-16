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
import 'package:offline_pos/features/sell/sell_screen.dart';
import 'package:offline_pos/features/shift/shift_screen.dart';
import 'package:offline_pos/features/support/diagnostics_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// No open shift, no sale.
///
/// A sale rung outside a shift belongs to no drawer and no Z. The till refuses to
/// start an order at all until one is open, and sends the cashier to open it. What
/// it must never refuse is the way out: the drawer, the support screens and the
/// shift screen itself all stay reachable.
void main() {
  late Db db;
  late ShiftStore shifts;
  late AuditLog audit;

  const cash = PaymentMethod(id: 1, name: 'Cash', isCash: true);

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    shifts = ShiftStore(db);
    audit = AuditLog(db);
    SettingsStore(db);
    CatalogueStore(db).replaceAll(
      categories: const [Category(id: 1, name: 'Pizza')],
      products: const [Product(id: 10, name: 'Margherita', price: 250, categoryId: 1)],
      groups: const [],
      productGroupIds: const {},
      paymentMethods: const [cash],
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
      orders: OrderStore(db),
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
      shifts: shifts,
      deviceId: 'till-1',
      endpoints: OdooEndpointStore(db),
      odoo: OdooWiring(outbox: outbox),
      tables: TableStore(db),
      settings: SettingsStore(db),
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

  /// A till-shaped window: the keypad and the drawer both want the height.
  void tallWindow(WidgetTester t) {
    t.view.physicalSize = const Size(1000, 2400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

  /// Sign in and land on the till, which is where an order would be started.
  Future<void> onTheTill(WidgetTester t) async {
    tallWindow(t);
    await t.pumpWidget(app());
    await signIn(t);
    await t.tap(find.byKey(const Key('floor-takeaway')));
    await t.pumpAndSettle();
    expect(find.byType(SellScreen), findsOneWidget);
  }

  testWidgets('with no shift open the till refuses to start an order', (t) async {
    await onTheTill(t);

    expect(find.byKey(const Key('no-shift-gate')), findsOneWidget);
    expect(find.text('No shift is open'), findsOneWidget);
    // Nothing to ring up with: no grid, no cart, no Pay.
    expect(find.text('Margherita'), findsNothing);
    expect(find.byKey(const Key('pay')), findsNothing);
    expect(find.byKey(const Key('search')), findsNothing);
  });

  testWidgets('the refusal opens the shift, and the till sells again', (t) async {
    await onTheTill(t);

    await t.tap(find.byKey(const Key('no-shift-open-shift')));
    await t.pumpAndSettle();
    expect(find.byType(ShiftScreen), findsOneWidget);

    // Open with a hundred on the float, the way a cashier starts the day.
    await t.tap(find.byKey(const Key('open-shift')));
    await t.pumpAndSettle();
    for (final d in '100'.split('')) {
      await t.tap(find.byKey(Key('key-$d')));
      await t.pump();
    }
    await t.tap(find.byKey(const Key('keypad-ok')));
    await t.pumpAndSettle();
    expect(shifts.currentOpenShift(), isNotNull);

    // Back to the till, which is open for business without a restart.
    await t.pageBack();
    await t.pumpAndSettle();
    expect(find.byKey(const Key('no-shift-gate')), findsNothing);

    await t.tap(find.text('Margherita'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('pay')), findsOneWidget);
  });

  testWidgets('a closed drawer does not lock the cashier out of a reprint',
      (t) async {
    await onTheTill(t);

    // The drawer is the way to everything that is not selling, and it is still
    // there: support carries the receipt reprints.
    await t.tap(find.byTooltip('Open navigation menu'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-support')));
    await t.pumpAndSettle();

    expect(find.byType(DiagnosticsScreen), findsOneWidget);
  });

  testWidgets('a till with a shift open is not gated at all', (t) async {
    shifts.openShift(openingFloat: 100, cashierId: 'sara');
    await onTheTill(t);

    expect(find.byKey(const Key('no-shift-gate')), findsNothing);
    expect(find.text('Margherita'), findsOneWidget);
  });
}
