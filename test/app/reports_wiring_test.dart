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

/// The new reports as a manager actually reaches them: through the drawer of a
/// running app, on the till's own local data.
///
/// The report maths is covered by the screen tests. What is covered here is the
/// seam: the shell must hand the hub the shift store and the open-table count,
/// or the expenses report and the glance card are dead screens nobody can feed.
void main() {
  late Db db;
  late OrderStore orders;
  late ShiftStore shifts;
  late SettingsStore settings;
  late AuditLog audit;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    orders = OrderStore(db);
    shifts = ShiftStore(db);
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
      shifts: shifts,
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

  Order sale(double amount, {OrderState state = OrderState.paid, String? table}) {
    final order = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      type: table == null ? OrderType.takeaway : OrderType.dineIn,
      tableLabel: table,
      state: state,
    )..lines.add(
        OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: amount));
    orders.save(order, announce: false);
    return order;
  }

  /// An order being rung keeps sign-in on the sell screen instead of opening the
  /// floor, which is where the navigation drawer lives.
  void draftOnTheTill() => sale(10, state: OrderState.draft);

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

  /// Opens the navigation drawer and taps through to the reports hub, the way a
  /// manager does it.
  Future<void> openReports(WidgetTester t) async {
    t.state<ScaffoldState>(find
            .descendant(of: find.byType(SellScreen), matching: find.byType(Scaffold))
            .first)
        .openDrawer();
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-report')));
    await t.pumpAndSettle();
  }

  void tallWindow(WidgetTester t) {
    t.view.physicalSize = const Size(1000, 3200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

  testWidgets('the hub the app opens carries today, the drawer and the floor',
      (t) async {
    tallWindow(t);
    draftOnTheTill();
    sale(100);
    sale(60);
    // A tab parked on a table is an open table, whichever till holds it.
    sale(30, state: OrderState.held, table: '5');

    await t.pumpWidget(app());
    await signIn(t);
    await openReports(t);

    expect(find.byKey(const Key('today-glance')), findsOneWidget);
    // Two paid sales at 100 and 60; the held tab is not takings.
    expect(find.textContaining('160'), findsWidgets);
    expect(
      t
          .widgetList<Text>(find.descendant(
              of: find.byKey(const Key('glance-tables')),
              matching: find.byType(Text)))
          .last
          .data,
      '1',
      reason: 'the shell must pass the open-table count or the tile is dead',
    );
  });

  testWidgets('a paid-out rung on the till shows in the expenses report',
      (t) async {
    tallWindow(t);
    draftOnTheTill();
    shifts.openShift(openingFloat: 100, cashierId: 'sara');
    shifts.addMovement('out', 25, reason: 'Taxi for delivery', category: 'Transport');

    await t.pumpWidget(app());
    await signIn(t);
    await openReports(t);

    await t.tap(find.byKey(const Key('rep-expenses')));
    await t.pumpAndSettle();

    expect(find.text('Taxi for delivery'), findsOneWidget);
    expect(find.textContaining('Transport'), findsWidgets);
  });

  testWidgets('a void rung on the till reaches the refunds & voids report',
      (t) async {
    tallWindow(t);
    draftOnTheTill();
    audit.record('sara', 'line.voided', detail: 'uuid-1|Pizza x1|Sent back');

    await t.pumpWidget(app());
    await signIn(t);
    await openReports(t);

    await t.tap(find.byKey(const Key('rep-refunds')));
    await t.pumpAndSettle();

    expect(find.textContaining('Pizza x1'), findsOneWidget);
    expect(find.text('Sent back'), findsWidgets);
  });
}
