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
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/orders/open_orders_screen.dart';
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

/// Open orders with no shift open.
///
/// The list is reachable from the floor drawer whether or not a drawer is open, and
/// recalling from it used to land on the counter's refusal with nothing to do next.
/// It is gated the way the floor gates a table tap now, and the refusal offers the
/// shift screen. What is never taken away is looking: a cashier with no shift still
/// has every right to see what is parked and to print a bill from it.
void main() {
  late Db db;
  late ShiftStore shifts;
  late OrderStore orders;
  late AuditLog audit;

  const cash = PaymentMethod(id: 1, name: 'Cash', isCash: true);

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    // No shift opened here: that is the whole point of these.
    shifts = ShiftStore(db);
    orders = OrderStore(db);
    audit = AuditLog(db);
    SettingsStore(db);
    TableStore(db).add(name: '5', seats: 4);
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

  /// A tab left parked on table 5 by the shift before this one, which is exactly
  /// how a cashier ends up looking at this list with no drawer of their own open.
  Order parkedTab() {
    final tab = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      type: OrderType.dineIn,
      tableLabel: '5',
    )
      ..state = OrderState.held
      ..lines.add(
          OrderLine(productId: 10, name: 'Margherita', quantity: 1, unitPrice: 250));
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

  /// A till-shaped window: the list, the strip and the keypad all want the height.
  void tallWindow(WidgetTester t) {
    t.view.physicalSize = const Size(1000, 2400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
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
      if (find.byKey(const Key('pin-ok')).evaluate().isEmpty) break;
    }
    await t.pumpAndSettle();
  }

  /// Sign in on a till with a parked tab and walk to Open orders the way a cashier
  /// does: through the floor drawer.
  Future<void> onTheList(WidgetTester t) async {
    tallWindow(t);
    await t.pumpWidget(app());
    await signIn(t);
    await t.tap(find.byTooltip('Open navigation menu'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-open-orders')));
    await t.pumpAndSettle();
    expect(find.byType(OpenOrdersScreen), findsOneWidget);
  }

  testWidgets('the parked tab is still there to look at', (t) async {
    final tab = parkedTab();
    await onTheList(t);

    expect(find.byKey(Key('open-order-${tab.uuid}')), findsOneWidget);
    expect(find.byKey(const Key('open-orders-no-shift')), findsOneWidget);
  });

  testWidgets('recalling says why instead of landing on the gated counter',
      (t) async {
    final tab = parkedTab();
    await onTheList(t);

    await t.tap(find.byKey(Key('recall-${tab.uuid}')));
    await t.pumpAndSettle();

    // The list stays put, so the cashier is looking at the thing they asked for
    // and at the way to fix it, not at a counter that refuses them.
    expect(find.byType(OpenOrdersScreen), findsOneWidget);
    expect(find.byType(SellScreen), findsNothing);
    expect(find.textContaining('pick a tab back up'), findsWidgets);
    // Untouched: nothing was recalled, so it is still parked for whoever opens up.
    expect(orders.byUuid(tab.uuid)!.state, OrderState.held);
  });

  testWidgets('the refusal opens the shift, and then the tab comes back',
      (t) async {
    final tab = parkedTab();
    await onTheList(t);

    await t.tap(find.byKey(const Key('open-orders-open-shift')));
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

    // Back on the list, which re-reads the drawer rather than keeping the strip up.
    await t.pageBack();
    await t.pumpAndSettle();
    expect(find.byKey(const Key('open-orders-no-shift')), findsNothing);

    await t.tap(find.byKey(Key('recall-${tab.uuid}')));
    await t.pumpAndSettle();
    expect(find.byType(SellScreen), findsOneWidget);
    expect(find.byKey(Key('line-${tab.lines.single.uuid}')), findsOneWidget);
  });

  testWidgets('printing the bill is never gated, because it is not selling',
      (t) async {
    final tab = parkedTab();
    await onTheList(t);

    await t.tap(find.byKey(Key('print-bill-${tab.uuid}')));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('bill-printed')), findsOneWidget);
    expect(find.byType(OpenOrdersScreen), findsOneWidget);
  });
}
