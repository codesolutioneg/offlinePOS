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
import 'package:offline_pos/features/tables/table_floor_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// Several people on one till: whose tab is whose, and how a manager moves them.
///
/// Every one of these drives the real floor of a real app shell, because the whole
/// feature is a prompt in front of a tap: a setting nothing reads would pass a store
/// test and still let anyone open anyone's table.
void main() {
  late Db db;
  late OrderStore orders;
  late SettingsStore settings;
  late AuditLog audit;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    // The till refuses to start an order with no shift open, so a test that
    // sells opens the drawer first.
    ShiftStore(db).openShift(openingFloat: 100, cashierId: 'sara');
    orders = OrderStore(db, ownDeviceId: 'till-1');
    settings = SettingsStore(db);
    audit = AuditLog(db);
    TableStore(db).add(name: '5');
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

  /// A tab Ana parked on table 5 before Sara came on.
  Order anasTab() {
    final tab = Order(
      deviceId: 'till-1',
      cashierId: 'ana',
      type: OrderType.dineIn,
      tableLabel: '5',
    )
      ..state = OrderState.held
      ..lines.add(OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 100));
    orders.save(tab, announce: false);
    return tab;
  }

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

  Future<void> tapTableFive(WidgetTester t) async {
    final tile = find.byWidgetPredicate(
        (w) => w is InkWell && '${w.key}'.startsWith('[<\'table-tile-'));
    await t.tap(tile.first);
    await t.pumpAndSettle();
  }

  Future<void> enterPin(WidgetTester t, String pin) async {
    await t.enterText(find.byKey(const Key('tab-pin')), pin);
    await t.tap(find.byKey(const Key('tab-pin-ok')));
    await t.pumpAndSettle();
  }

  testWidgets('with the setting off anyone picks up any tab', (t) async {
    final tab = anasTab();

    await t.pumpWidget(app());
    await signIn(t, 'sara', '1234');
    await tapTableFive(t);

    expect(find.byKey(const Key('tab-pin')), findsNothing);
    expect(find.byType(SellScreen), findsOneWidget);
    expect(orders.byUuid(tab.uuid)!.state, OrderState.draft);
  });

  testWidgets('with it on, another cashier is asked whose tab it is', (t) async {
    settings.tableSecurity = true;
    final tab = anasTab();

    await t.pumpWidget(app());
    await signIn(t, 'sara', '1234');
    await tapTableFive(t);

    expect(find.byKey(const Key('tab-pin')), findsOneWidget);
    expect(find.textContaining('Ana'), findsOneWidget);
    // Walking away leaves the tab exactly where it was.
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(orders.byUuid(tab.uuid)!.state, OrderState.held);
    expect(find.byType(TableFloorScreen), findsOneWidget);
  });

  testWidgets('the cashier who opened it unlocks it with their own PIN', (t) async {
    settings.tableSecurity = true;
    final tab = anasTab();

    await t.pumpWidget(app());
    await signIn(t, 'sara', '1234');
    await tapTableFive(t);
    await enterPin(t, '4321');

    expect(orders.byUuid(tab.uuid)!.state, OrderState.draft);
    expect(find.byType(SellScreen), findsOneWidget);
    // Ana unlocked her tab without taking the till: Sara is still the cashier on it.
    expect(orders.byUuid(tab.uuid)!.cashierId, 'ana');
  });

  testWidgets('a manager PIN opens it too, and a wrong one does not', (t) async {
    settings.tableSecurity = true;
    final tab = anasTab();

    await t.pumpWidget(app());
    await signIn(t, 'sara', '1234');
    await tapTableFive(t);
    await enterPin(t, '1111');
    expect(orders.byUuid(tab.uuid)!.state, OrderState.held);
    expect(find.text('That PIN did not open this tab'), findsOneWidget);

    await tapTableFive(t);
    await enterPin(t, '9999');
    expect(orders.byUuid(tab.uuid)!.state, OrderState.draft);
  });

  testWidgets('your own tab is never in your way', (t) async {
    settings.tableSecurity = true;
    final tab = anasTab();

    await t.pumpWidget(app());
    await signIn(t, 'ana', '4321');
    await tapTableFive(t);

    expect(find.byKey(const Key('tab-pin')), findsNothing);
    expect(orders.byUuid(tab.uuid)!.state, OrderState.draft);
  });

  testWidgets('a cashier cannot switch the rule off to get at a tab', (t) async {
    settings.tableSecurity = true;
    anasTab();

    await t.pumpWidget(app());
    await signIn(t, 'sara', '1234');
    await t.tap(find.byKey(const Key('floor-menu')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('floor-table-security')));
    await t.pumpAndSettle();

    // The manager gate, not the switch: otherwise the lock has its own key taped
    // to it.
    expect(find.byKey(const Key('manager-pin')), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(settings.tableSecurity, isTrue);
  });

  testWidgets('a manager moves a waiter\'s tables to whoever is on now', (t) async {
    settings.tableSecurity = true;
    final tab = anasTab();

    await t.pumpWidget(app());
    await signIn(t, 'mo', '9999');
    await t.tap(find.byKey(const Key('floor-menu')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('floor-transfer-tables')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('transfer-ana')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('transfer-mo')));
    await t.pumpAndSettle();

    expect(orders.byUuid(tab.uuid)!.cashierId, 'mo');
    expect(orders.byUuid(tab.uuid)!.state, OrderState.held,
        reason: 'a transfer moves the tab, it does not open it');
    // And now it opens with no prompt, because it is the manager's own.
    await tapTableFive(t);
    expect(find.byKey(const Key('tab-pin')), findsNothing);
    expect(orders.byUuid(tab.uuid)!.state, OrderState.draft);
  });

  testWidgets('the same question is asked from the open orders list', (t) async {
    settings.tableSecurity = true;
    final tab = anasTab();

    await t.pumpWidget(app());
    await signIn(t, 'sara', '1234');
    // Off the floor and onto the counter, then into the list of parked tabs.
    await t.tap(find.byKey(const Key('floor-takeaway')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('open-orders')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('open-order-${tab.uuid}')));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('tab-pin')), findsOneWidget,
        reason: 'the list must not be a way around the prompt');
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(orders.byUuid(tab.uuid)!.state, OrderState.held);
  });
}
