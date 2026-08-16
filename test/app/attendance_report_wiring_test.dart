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

/// The hours report as a manager reaches it: through the drawer of a running app,
/// on clock-ins this till recorded, with nothing but the local database behind it.
void main() {
  late Db db;
  late OrderStore orders;
  late AttendanceStore attendance;
  late UserStore users;
  late AuditLog audit;
  var clock = DateTime.utc(2026, 8, 10, 9);

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    orders = OrderStore(db);
    users = UserStore(db);
    audit = AuditLog(db);
    clock = DateTime.utc(2026, 8, 10, 9);
    attendance = AttendanceStore(db, now: () => clock);
    final auth = AuthService(users: users, hasher: FakePinHasher(), audit: audit);
    await auth.enrol(id: 'sara', name: 'Sara', pin: '1234');
    await auth.enrol(id: 'omar', name: 'Omar', pin: '5678');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');
  });
  tearDown(() => db.close());

  Widget app() {
    final outbox = Outbox(store: SqliteOutboxStore(db), senders: {});
    return PosApp(
      auth: AuthService(users: users, hasher: FakePinHasher(), audit: audit),
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
      printers: PrinterRegistry(discovery: _NoPrinters()),
      wizards: WizardStore(db),
      shifts: ShiftStore(db),
      deviceId: 'till-1',
      endpoints: OdooEndpointStore(db),
      odoo: OdooWiring(outbox: outbox),
      tables: TableStore(db),
      settings: SettingsStore(db),
      customers: CustomerStore(db),
      attendance: attendance,
      config: const TillConfig(),
    );
  }

  /// An order being rung keeps sign-in on the sell screen, which is where the
  /// navigation drawer lives.
  void draftOnTheTill() {
    orders.save(
        Order(deviceId: 'till-1', cashierId: 'sara', type: OrderType.takeaway)
          ..lines.add(
              OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 10)),
        announce: false);
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

  Future<void> openReports(WidgetTester t) async {
    t.state<ScaffoldState>(find
            .descendant(of: find.byType(SellScreen), matching: find.byType(Scaffold))
            .first)
        .openDrawer();
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-report')));
    await t.pumpAndSettle();
    // Over the whole history, so the fixture's dates are not a clock race.
    await t.tap(find.byKey(const Key('range-all')));
    await t.pumpAndSettle();
  }

  void tallWindow(WidgetTester t) {
    t.view.physicalSize = const Size(1000, 3200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

  void workedShift(String who, DateTime from, Duration length) {
    clock = from;
    attendance.clockIn(who);
    clock = from.add(length);
    attendance.clockOut(who);
  }

  testWidgets('hours clocked on this till are readable back, by name', (t) async {
    tallWindow(t);
    draftOnTheTill();
    workedShift('sara', DateTime.utc(2026, 8, 10, 9), const Duration(hours: 4));
    workedShift('sara', DateTime.utc(2026, 8, 11, 9), const Duration(hours: 5));
    workedShift('omar', DateTime.utc(2026, 8, 11, 18), const Duration(hours: 2));

    await t.pumpWidget(app());
    await signIn(t);
    await openReports(t);

    expect(find.byKey(const Key('rep-attendance')), findsOneWidget,
        reason: 'the shell must hand the hub the attendance store, or the tile is '
            'a dead screen nobody can feed');
    await t.tap(find.byKey(const Key('rep-attendance')));
    await t.pumpAndSettle();

    // Names, not ids: the shell has to pass the roster too.
    expect(find.text('Sara'), findsOneWidget);
    expect(find.text('Omar'), findsOneWidget);
    expect(find.text('9h 0m'), findsWidgets);
    expect(find.text('11h 0m'), findsOneWidget);
  });

  testWidgets('the cashier filter narrows the hours to one person', (t) async {
    tallWindow(t);
    draftOnTheTill();
    // The filter offers the cashiers who appear in the sales, so give it one.
    orders.save(
        Order(
            deviceId: 'till-1',
            cashierId: 'sara',
            type: OrderType.takeaway,
            state: OrderState.paid)
          ..lines.add(
              OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 10)),
        announce: false);
    workedShift('sara', DateTime.utc(2026, 8, 10, 9), const Duration(hours: 4));
    workedShift('omar', DateTime.utc(2026, 8, 11, 18), const Duration(hours: 2));

    await t.pumpWidget(app());
    await signIn(t);
    await openReports(t);

    await t.tap(find.byKey(const Key('report-cashier-filter')));
    await t.pumpAndSettle();
    await t.tap(find.text('sara').last);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('rep-attendance')));
    await t.pumpAndSettle();

    expect(find.text('Sara'), findsOneWidget);
    expect(find.text('Omar'), findsNothing);
  });
}
