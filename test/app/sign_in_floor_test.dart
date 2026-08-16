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

/// Where a cashier stands, and what puts them there.
///
/// A restaurant till sits on its floor plan: signing in lands on the room, an order
/// is what opens the counter, and finishing one comes straight back. The one route
/// that skips the floor is crash recovery, because half a bill with a customer in
/// front of it is not something to make a cashier go and find.
void main() {
  late Db db;
  late OrderStore orders;
  late TableStore tables;
  late PosTable table5;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    orders = OrderStore(db, ownDeviceId: 'till-1');
    tables = TableStore(db);
    table5 = tables.add(name: '5', seats: 4);
    // A drawer is open, so nothing here is refused for the wrong reason. The
    // no-shift refusal on the floor has its own suite, in shift_gate_test.
    ShiftStore(db).openShift(openingFloat: 100, cashierId: 'sara');
    CatalogueStore(db).replaceAll(
      categories: const [Category(id: 1, name: 'Food')],
      products: const [Product(id: 10, name: 'Pizza', price: 250, categoryId: 1)],
      groups: const [],
      productGroupIds: const {},
      paymentMethods: const [PaymentMethod(id: 1, name: 'Cash', isCash: true)],
      refreshedAt: DateTime.now().toUtc(),
    );
    final audit = AuditLog(db);
    await AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'sara', name: 'Sara', pin: '1234');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');
  });
  tearDown(() => db.close());

  Widget app() {
    final outbox = Outbox(store: SqliteOutboxStore(db), senders: {});
    final audit = AuditLog(db);
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
      tables: tables,
      settings: SettingsStore(db),
      customers: CustomerStore(db),
      attendance: AttendanceStore(db),
      config: const TillConfig(),
    );
  }

  /// A till-shaped window, so the cart and the grid both fit beside each other.
  Future<void> boot(WidgetTester t) async {
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
    // The PIN check resolves off the frame pipeline, so give the microtask queue
    // real time rather than trusting one settle.
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 50));
      if (find.byKey(const Key('pin-ok')).evaluate().isEmpty) break;
    }
    await t.pumpAndSettle();
  }

  /// Seat table 5 and ring one pizza on it.
  Future<void> seatAndRing(WidgetTester t) async {
    await t.tap(find.byKey(Key('table-tile-${table5.id}')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('product-10')));
    await t.pumpAndSettle();
  }

  testWidgets('signing in with nothing on the till lands on the floor', (t) async {
    await boot(t);

    expect(find.byType(TableFloorScreen), findsOneWidget);
    expect(find.byType(SellScreen), findsNothing,
        reason: 'the counter is what an order opens, not what a shift opens on');
  });

  testWidgets('tapping a table opens the counter on that order', (t) async {
    await boot(t);

    await t.tap(find.byKey(Key('table-tile-${table5.id}')));
    await t.pumpAndSettle();

    expect(find.byType(SellScreen), findsOneWidget);
    expect(find.byType(TableFloorScreen), findsNothing);
    // Seated where it was tapped, which is what the bill has to say.
    expect(find.widgetWithText(ActionChip, 'Table 5'), findsOneWidget);
  });

  testWidgets('the takeaway button opens the counter with no table', (t) async {
    await boot(t);

    await t.tap(find.byKey(const Key('floor-takeaway')));
    await t.pumpAndSettle();

    expect(find.byType(SellScreen), findsOneWidget);
    final chip =
        t.widget<ChoiceChip>(find.byKey(const Key('order-type-takeaway')));
    expect(chip.selected, isTrue);
  });

  testWidgets('taking the money puts the cashier back on the floor', (t) async {
    await boot(t);
    await seatAndRing(t);

    await t.tap(find.byKey(const Key('pay')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('method-1')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-payment')));
    await t.pumpAndSettle();

    expect(find.byType(TableFloorScreen), findsOneWidget);
    expect(find.byType(SellScreen), findsNothing);
    // The sale is booked and the table is free again for the next guests.
    expect(orders.recent().single.state, OrderState.paid);
    expect(orders.held(), isEmpty);
    expect(find.text('Free'), findsOneWidget);
  });

  testWidgets('parking a bill puts the cashier back on the floor', (t) async {
    await boot(t);
    await seatAndRing(t);

    await t.tap(find.byKey(const Key('hold')));
    await t.pumpAndSettle();

    expect(find.byType(TableFloorScreen), findsOneWidget);
    expect(find.byType(SellScreen), findsNothing);
    expect(orders.held().single.tableLabel, '5');
    // And the room says which table is holding it.
    expect(find.text('Free'), findsNothing);
    expect(find.text('250.00'), findsOneWidget);
  });

  testWidgets('backing out of an unpaid order parks it rather than losing it',
      (t) async {
    await boot(t);
    await seatAndRing(t);
    final ringing = orders.drafts().single;

    // The way off the counter, which is the floor the order was started from.
    await t.tap(find.byKey(const Key('new-order')));
    await t.pumpAndSettle();

    expect(find.byType(TableFloorScreen), findsOneWidget);
    // Parked, not left as a draft: this is the only state the floor tile, the
    // open-orders list and the parked-delivery prompt can all find again.
    final parked = orders.held().single;
    expect(parked.uuid, ringing.uuid);
    expect(parked.lines.single.name, 'Pizza');
    expect(parked.tableLabel, '5');
    expect(orders.drafts(), isEmpty);
    // The table reads as taken, so nobody seats a walk-in on top of the bill.
    expect(find.text('Free'), findsNothing);
    expect(find.text('250.00'), findsOneWidget);

    // And tapping it again brings the same bill back to the counter, with nothing
    // sitting over the plan to wait out first.
    await t.tap(find.byKey(Key('table-tile-${table5.id}')));
    await t.pumpAndSettle();
    expect(find.byType(SellScreen), findsOneWidget);
    expect(find.byKey(Key('line-${parked.lines.single.uuid}')), findsOneWidget);
  });

  testWidgets('a draft restored after a crash lands on the counter, not the floor',
      (t) async {
    orders.save(
      Order(deviceId: 'till-1', cashierId: 'sara', tableLabel: '5')
        ..lines.add(
            OrderLine(productId: 10, name: 'Pizza', quantity: 1, unitPrice: 250)),
      announce: false,
    );

    await boot(t);

    expect(find.byType(SellScreen), findsOneWidget);
    expect(find.byType(TableFloorScreen), findsNothing);
    expect(find.widgetWithText(ActionChip, 'Table 5'), findsOneWidget);
  });
}
