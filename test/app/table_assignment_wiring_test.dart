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
import 'package:offline_pos/core/db/table_assignment_store.dart';
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
import 'package:offline_pos/features/tables/table_floor_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// The room shared out between the waiters, driven through the real app shell.
///
/// A store test can prove a row exists; only the shell can prove a waiter is actually
/// stopped at the tile and a manager actually gets through. The whole feature is a
/// refusal in front of a tap, so that is what is tested.
void main() {
  late Db db;
  late OrderStore orders;
  late SettingsStore settings;
  late AuditLog audit;
  late TableStore tables;
  late TableAssignmentStore assignments;
  late ShiftStore shifts;
  late String tableFive;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    shifts = ShiftStore(db);
    // The till refuses to start an order with no shift open, so the drawer is open
    // for every one of these unless the test closes it.
    shifts.openShift(openingFloat: 100, cashierId: 'sara');
    orders = OrderStore(db, ownDeviceId: 'till-1');
    settings = SettingsStore(db);
    // These are about who may open a table, not about the covers, so seating stays
    // one tap: a guest prompt in the way would only be a second thing to answer.
    settings.askGuestCount = false;
    audit = AuditLog(db);
    tables = TableStore(db);
    assignments = TableAssignmentStore(db);
    tableFive = tables.add(name: '5').id;
    tables.add(name: '6');
    final auth =
        AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit);
    await auth.enrol(id: 'sara', name: 'Sara', pin: '1234');
    await auth.enrol(id: 'ana', name: 'Ana', pin: '4321');
    await auth.enrol(id: 'mo', name: 'Mo', pin: '9999', role: 'manager');
    for (final id in ['sara', 'ana', 'mo']) {
      WizardStore(db).dismiss(WizardId.firstSale, id);
    }
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
      tables: tables,
      settings: settings,
      customers: CustomerStore(db),
      attendance: AttendanceStore(db),
      assignments: assignments,
      config: const TillConfig(),
    );
  }

  Future<void> signIn(WidgetTester t, String id, String pin) async {
    await t.tap(find.byKey(Key('user-$id')));
    await t.pumpAndSettle();
    for (final d in pin.split('')) {
      await t.tap(find.byKey(Key('key-$d')));
      await t.pump();
    }
    await t.tap(find.byKey(const Key('pin-ok')));
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 50));
      if (find.byType(TableFloorScreen).evaluate().isNotEmpty) break;
    }
    await t.pumpAndSettle();
  }

  Future<void> tapFive(WidgetTester t) async {
    await t.tap(find.byKey(Key('table-tile-$tableFive')));
    await t.pumpAndSettle();
  }

  Future<void> managerPin(WidgetTester t, String pin) async {
    await t.enterText(find.byKey(const Key('manager-pin')), pin);
    await t.tap(find.byKey(const Key('manager-ok')));
    await t.pumpAndSettle();
  }

  testWidgets('a waiter is stopped at a table that is not theirs', (t) async {
    assignments.assign(tableFive, 'ana', by: 'mo');

    await t.pumpWidget(app());
    await signIn(t, 'sara', '1234');

    // Seen and named on the plan, so Sara knows it is Ana's rather than broken.
    expect(find.byKey(Key('table-locked-$tableFive')), findsOneWidget);
    expect(find.text('Ana'), findsOneWidget);

    await tapFive(t);
    expect(find.byKey(const Key('foreign-table-dialog')), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();

    // Nothing started: still on the floor, no order on the counter.
    expect(find.byType(SellScreen), findsNothing);
    expect(find.byType(TableFloorScreen), findsOneWidget);
  });

  testWidgets('a manager PIN opens somebody else\'s table', (t) async {
    assignments.assign(tableFive, 'ana', by: 'mo');

    await t.pumpWidget(app());
    await signIn(t, 'sara', '1234');
    await tapFive(t);
    await t.tap(find.byKey(const Key('foreign-table-approve')));
    await t.pumpAndSettle();
    await managerPin(t, '9999');

    expect(find.byType(SellScreen), findsOneWidget);
  });

  testWidgets('a wrong PIN leaves the table shut', (t) async {
    assignments.assign(tableFive, 'ana', by: 'mo');

    await t.pumpWidget(app());
    await signIn(t, 'sara', '1234');
    await tapFive(t);
    await t.tap(find.byKey(const Key('foreign-table-approve')));
    await t.pumpAndSettle();
    await managerPin(t, '1111');

    expect(find.byType(SellScreen), findsNothing);
    expect(audit.recent(event: 'permission.denied'), isNotEmpty);
  });

  testWidgets('a waiter opens their own assigned table with no prompt', (t) async {
    assignments.assign(tableFive, 'sara', by: 'mo');

    await t.pumpWidget(app());
    await signIn(t, 'sara', '1234');

    expect(find.byKey(Key('table-locked-$tableFive')), findsNothing);
    await tapFive(t);

    expect(find.byKey(const Key('foreign-table-dialog')), findsNothing);
    expect(find.byType(SellScreen), findsOneWidget);
  });

  testWidgets('an unassigned table stays open to whoever is on the till', (t) async {
    assignments.assign(tableFive, 'ana', by: 'mo');
    final six = tables.byName('6')!;

    await t.pumpWidget(app());
    await signIn(t, 'sara', '1234');
    await t.tap(find.byKey(Key('table-tile-${six.id}')));
    await t.pumpAndSettle();

    expect(find.byType(SellScreen), findsOneWidget);
  });

  testWidgets('a manager walks onto any table with no dialog at all', (t) async {
    assignments.assign(tableFive, 'ana', by: 'mo');

    await t.pumpWidget(app());
    await signIn(t, 'mo', '9999');

    expect(find.byKey(Key('table-locked-$tableFive')), findsNothing);
    await tapFive(t);

    expect(find.byKey(const Key('foreign-table-dialog')), findsNothing);
    expect(find.byType(SellScreen), findsOneWidget);
  });

  testWidgets('the manager shares the room out from the floor, and it is audited',
      (t) async {
    await t.pumpWidget(app());
    await signIn(t, 'mo', '9999');

    // Offered at the start of the service, since nothing is assigned yet.
    expect(find.byKey(const Key('floor-assign-hint')), findsOneWidget);
    await t.tap(find.byKey(const Key('floor-assign-now')));
    await t.pumpAndSettle();

    await t.tap(find.byKey(Key('table-assign-$tableFive')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('assign-to-ana')));
    await t.pumpAndSettle();

    expect(assignments.cashierFor(tableFive), 'ana');
    final trail = audit.recent(event: 'table.assigned');
    expect(trail.any((e) => e['detail'] == '5|ana'), isTrue);
    // And it is on the tile straight away: the manager has to see the room fill up as
    // they share it out, not after leaving the screen and coming back.
    expect(find.text('Ana'), findsOneWidget);
    expect(find.byKey(const Key('floor-assign-hint')), findsNothing);
  });

  testWidgets('a waiter cannot share the room out without a manager', (t) async {
    await t.pumpWidget(app());
    await signIn(t, 'sara', '1234');

    // No nudge for somebody who cannot act on it, but the action is still there so a
    // manager can be called over to a handheld.
    expect(find.byKey(const Key('floor-assign-hint')), findsNothing);
    await t.tap(find.byKey(const Key('toggle-assign')));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('manager-pin')), findsOneWidget);
    await managerPin(t, '1111');
    expect(find.byKey(const Key('floor-assigning')), findsNothing);
    expect(assignments.isEmpty, isTrue);
  });

  testWidgets('a tab on somebody else\'s table is refused from Open orders too',
      (t) async {
    // The bypass this closes: the tile is refused, but the same tab is one tap away
    // in the Open orders list, and a rule that only holds on one screen is not one.
    assignments.assign(tableFive, 'ana', by: 'mo');
    final tab = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      type: OrderType.dineIn,
      tableLabel: '5',
    )
      ..state = OrderState.held
      ..lines.add(OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 100));
    orders.save(tab, announce: false);

    await t.pumpWidget(app());
    await signIn(t, 'sara', '1234');
    await t.tap(find.byTooltip('Open navigation menu'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-open-orders')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('recall-${tab.uuid}')));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('manager-pin')), findsOneWidget);
    await managerPin(t, '1111');
    expect(orders.byUuid(tab.uuid)!.state, OrderState.held);
  });

  testWidgets('the Z hands the whole room back for the next service', (t) async {
    assignments.assign(tableFive, 'ana', by: 'mo');

    await t.pumpWidget(app());
    await signIn(t, 'mo', '9999');
    await t.tap(find.byKey(const Key('floor-takeaway')));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Open navigation menu'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-shift')));
    await t.pumpAndSettle();
    expect(find.byType(ShiftScreen), findsOneWidget);

    await t.tap(find.byKey(const Key('close-shift')));
    await t.pumpAndSettle();
    for (final d in '100'.split('')) {
      await t.tap(find.byKey(Key('key-$d')));
      await t.pump();
    }
    await t.tap(find.byKey(const Key('keypad-ok')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-close-shift')));
    await t.pumpAndSettle();

    expect(shifts.currentOpenShift(), isNull);
    expect(assignments.isEmpty, isTrue);
    expect(audit.recent(event: 'tables.unassigned_all'), isNotEmpty);
  });
}
