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
import 'package:offline_pos/features/shift/shift_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// Closing the day over work that is not finished, or over a drawer that does not
/// add up.
///
/// A Z is irreversible and it is when the day's sales are pushed. A tab still on a
/// table, a course still waiting on its timer, or a cash count that misses the
/// expected drawer all stop it outright: they are named on screen, and there is no
/// button and no manager PIN that closes over them.
void main() {
  late Db db;
  late OrderStore orders;
  late ShiftStore shifts;
  late AuditLog audit;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    orders = OrderStore(db, ownDeviceId: 'till-1');
    shifts = ShiftStore(db);
    audit = AuditLog(db);
    SettingsStore(db);
    shifts.openShift(openingFloat: 100, cashierId: 'sara');
  });
  tearDown(() => db.close());

  Future<AuthService> cashierOnTheTill({bool manager = false}) async {
    final auth = AuthService(
        users: UserStore(db), hasher: FakePinHasher(), audit: AuditLog(db));
    await auth.enrol(
        id: 'sara',
        name: 'Sara',
        pin: '1234',
        role: manager ? 'manager' : 'cashier');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');
    return auth;
  }

  Widget app(AuthService auth) {
    final outbox = Outbox(store: SqliteOutboxStore(db), senders: {});
    return PosApp(
      auth: auth,
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
      settings: SettingsStore(db),
      customers: CustomerStore(db),
      attendance: AttendanceStore(db),
      config: const TillConfig(),
    );
  }

  /// A tab parked on a table, which is exactly what must not be closed over
  /// unnoticed: the guests are still eating and nobody has taken their money.
  void parkedTab({DateTime? fireAt}) {
    final order = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      type: OrderType.dineIn,
      tableLabel: '7',
    )..lines.add(OrderLine(
        productId: 1,
        name: 'Steak',
        quantity: 1,
        unitPrice: 250,
        fireAt: fireAt));
    order.state = OrderState.held;
    orders.save(order);
  }

  /// A till-shaped window: the keypad and the drawer both want the height.
  void tallWindow(WidgetTester t) {
    t.view.physicalSize = const Size(1000, 2400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

  Future<void> signIn(WidgetTester t) async {
    tallWindow(t);
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

  /// Press Close and key the counted cash into the pad, which is as far as a cashier
  /// gets before the guards have their say.
  Future<void> countTheDrawer(WidgetTester t, String amount) async {
    await t.tap(find.byKey(const Key('close-shift')));
    await t.pumpAndSettle();
    for (final d in amount.split('')) {
      await t.tap(find.byKey(Key('key-$d')));
      await t.pump();
    }
    await t.tap(find.byKey(const Key('keypad-ok')));
    await t.pumpAndSettle();
  }

  /// Off the floor, through the drawer, onto the shift screen: the way a cashier
  /// reaches the cash-up.
  Future<void> openShiftScreen(WidgetTester t) async {
    await t.tap(find.byKey(const Key('floor-takeaway')));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Open navigation menu'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-shift')));
    await t.pumpAndSettle();
    expect(find.byType(ShiftScreen), findsOneWidget);
  }

  testWidgets('a Z over a parked tab is refused outright', (t) async {
    parkedTab();
    await t.pumpWidget(app(await cashierOnTheTill()));
    await signIn(t);
    await openShiftScreen(t);

    // Said on the screen beside the button, before it is even pressed.
    expect(find.text('Cannot close: still open on this till (1)'), findsOneWidget);

    await t.tap(find.byKey(const Key('close-shift')));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('open-work')), findsOneWidget);
    expect(find.text('Still open on this till (1)'), findsOneWidget);
    expect(find.text('7 - 250.00'), findsOneWidget);
    // No way through it: the only action is back to the floor to settle the tab.
    expect(find.byKey(const Key('close-over-open-work')), findsNothing);

    await t.tap(find.byKey(const Key('open-work-back')));
    await t.pumpAndSettle();
    expect(shifts.currentOpenShift(), isNotNull);
    expect(find.text('Counted cash'), findsNothing);
    expect(audit.recent(event: 'shift.close.blocked.open_work'), isNotEmpty);
  });

  testWidgets('a course still waiting to fire is named too', (t) async {
    parkedTab(fireAt: DateTime.utc(2026, 8, 15, 19, 30));
    await t.pumpWidget(app(await cashierOnTheTill()));
    await signIn(t);
    await openShiftScreen(t);

    await t.tap(find.byKey(const Key('close-shift')));
    await t.pumpAndSettle();

    expect(find.text('Courses waiting to fire'), findsOneWidget);
    expect(find.textContaining('Steak'), findsOneWidget);
  });

  testWidgets('a paid sale whose late course has not fired still counts',
      (t) async {
    // Paid and waiting for the shift-close batch, with the mains held back: the
    // money is in, the food is not out, and closing the day is not the end of it.
    final order = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      type: OrderType.takeaway,
    )..lines.add(OrderLine(
        productId: 2,
        name: 'Lamb',
        quantity: 1,
        unitPrice: 300,
        fireAt: DateTime.now().toUtc().add(const Duration(hours: 1))));
    order.state = OrderState.paid;
    orders.save(order);

    await t.pumpWidget(app(await cashierOnTheTill()));
    await signIn(t);
    await openShiftScreen(t);

    await t.tap(find.byKey(const Key('close-shift')));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('open-work')), findsOneWidget);
    expect(find.text('Parked tabs'), findsNothing);
    expect(find.textContaining('Lamb'), findsOneWidget);
  });

  testWidgets('not even a manager can close over a parked tab', (t) async {
    parkedTab();
    await t.pumpWidget(app(await cashierOnTheTill(manager: true)));
    await signIn(t);
    await openShiftScreen(t);

    await t.tap(find.byKey(const Key('close-shift')));
    await t.pumpAndSettle();

    // The role that overrides everything else on this till gets the same answer.
    expect(find.byKey(const Key('open-work')), findsOneWidget);
    expect(find.byKey(const Key('close-over-open-work')), findsNothing);
    expect(find.text('Counted cash'), findsNothing);
  });

  testWidgets('a count that misses the expected drawer will not close', (t) async {
    await t.pumpWidget(app(await cashierOnTheTill(manager: true)));
    await signIn(t);
    await openShiftScreen(t);

    // The float is a hundred and nothing was sold, so a hundred is the only count
    // that adds up. Ninety is nine short and the Z does not happen.
    await countTheDrawer(t, '90');

    expect(find.byKey(const Key('cash-variance-block')), findsOneWidget);
    expect(find.text('Expected in drawer: 100.00'), findsOneWidget);
    expect(find.text('Counted: 90.00'), findsOneWidget);
    expect(find.text('Variance: -10.00'), findsOneWidget);
    expect(find.text('Allowed difference: 0.00'), findsOneWidget);

    await t.tap(find.byKey(const Key('cash-variance-back')));
    await t.pumpAndSettle();
    expect(shifts.currentOpenShift(), isNotNull);
    expect(find.byKey(const Key('confirm-close-shift')), findsNothing);
    expect(audit.recent(event: 'shift.close.blocked.cash_variance'), isNotEmpty);
  });

  testWidgets('a drawer that matches to the cent reaches the confirmation',
      (t) async {
    await t.pumpWidget(app(await cashierOnTheTill(manager: true)));
    await signIn(t);
    await openShiftScreen(t);

    await countTheDrawer(t, '100');

    expect(find.byKey(const Key('cash-variance-block')), findsNothing);
    expect(find.byKey(const Key('confirm-close-shift')), findsOneWidget);
  });

  testWidgets('a shop that allows a small difference closes inside it', (t) async {
    SettingsStore(db).cashVarianceTolerance = 5;
    await t.pumpWidget(app(await cashierOnTheTill(manager: true)));
    await signIn(t);
    await openShiftScreen(t);

    // Two short, on a five allowance: within what the shop tolerates.
    await countTheDrawer(t, '98');

    expect(find.byKey(const Key('cash-variance-block')), findsNothing);
    expect(find.byKey(const Key('confirm-close-shift')), findsOneWidget);
  });

  testWidgets('a clean till closes without a word about open work', (t) async {
    await t.pumpWidget(app(await cashierOnTheTill(manager: true)));
    await signIn(t);
    await openShiftScreen(t);

    expect(find.byKey(const Key('close-blocked-why')), findsNothing);
    await t.tap(find.byKey(const Key('close-shift')));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('open-work')), findsNothing);
    expect(find.text('Counted cash'), findsOneWidget);
  });
}
