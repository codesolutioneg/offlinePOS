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
import 'package:offline_pos/features/tables/table_floor_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// What survives the trip between the floor and the counter, and what the till
/// says on the way back.
///
/// The floor is home and the counter replaces it, so anything the floor holds by
/// itself is thrown away on every single order. These are the three things a
/// waiter notices when it is: the room they were working, the seating they had
/// chosen, and where the "parked" confirmation lands.
void main() {
  late Db db;
  late OrderStore orders;
  late SettingsStore settings;
  late TableStore tables;
  late PosTable mainTable;
  late PosTable terraceTable;
  late AuditLog audit;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    ShiftStore(db).openShift(openingFloat: 100, cashierId: 'sara');
    orders = OrderStore(db);
    settings = SettingsStore(db);
    // Seating here is about what the floor remembers across a trip to the counter,
    // not about the covers, so the guest prompt is off: on by default it would sit in
    // front of every seating below.
    settings.askGuestCount = false;
    tables = TableStore(db);
    audit = AuditLog(db);
    // Two rooms, because the whole point is which of them the till comes back to.
    mainTable = tables.add(name: '5', seats: 4, section: 'Main');
    terraceTable = tables.add(name: 'T1', seats: 2, section: 'Terrace');
    CatalogueStore(db).replaceAll(
      categories: const [Category(id: 1, name: 'Pizza')],
      products: const [Product(id: 10, name: 'Margherita', price: 250, categoryId: 1)],
      groups: const [],
      productGroupIds: const {},
      refreshedAt: DateTime.now().toUtc(),
    );
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
      shifts: ShiftStore(db),
      deviceId: 'till-1',
      endpoints: OdooEndpointStore(db),
      odoo: OdooWiring(outbox: outbox),
      tables: tables,
      settings: settings,
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
      if (find.byKey(const Key('pin-ok')).evaluate().isEmpty) break;
    }
    await t.pumpAndSettle();
  }

  /// Open a counter and come straight back, which is what every order does. The
  /// to-go button is used because it needs no table and so cannot itself change
  /// which room is showing.
  Future<void> counterRoundTrip(WidgetTester t) async {
    await t.tap(find.byKey(const Key('floor-to-go')));
    await t.pumpAndSettle();
    expect(find.byType(SellScreen), findsOneWidget);
    await t.tap(find.byKey(const Key('new-order')));
    await t.pumpAndSettle();
    expect(find.byType(TableFloorScreen), findsOneWidget);
  }

  group('the room the waiter is working', () {
    testWidgets('survives a trip to the counter', (t) async {
      await t.pumpWidget(app());
      await signIn(t);

      await t.tap(find.byKey(const Key('section-terrace')));
      await t.pumpAndSettle();
      expect(find.byKey(Key('table-tile-${terraceTable.id}')), findsOneWidget);

      await counterRoundTrip(t);

      // Still the Terrace, not dropped back onto the first room.
      expect(find.byKey(Key('table-tile-${terraceTable.id}')), findsOneWidget);
      expect(find.byKey(Key('table-tile-${mainTable.id}')), findsNothing);
    });

    testWidgets('goes back to the first room when the till changes hands',
        (t) async {
      await t.pumpWidget(app());
      await signIn(t);

      await t.tap(find.byKey(const Key('section-terrace')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('sign-out')));
      await t.pumpAndSettle();
      await signIn(t);

      // The room belongs to the waiter who chose it, not to the next one.
      expect(find.byKey(Key('table-tile-${mainTable.id}')), findsOneWidget);
      expect(find.byKey(Key('table-tile-${terraceTable.id}')), findsNothing);
    });

    testWidgets('and so does the seating the waiter chose', (t) async {
      await t.pumpWidget(app());
      await signIn(t);

      await t.tap(find.byKey(const Key('seat-as-togo')));
      await t.pumpAndSettle();

      await counterRoundTrip(t);

      final chip = t.widget<ChoiceChip>(find.byKey(const Key('seat-as-togo')));
      expect(chip.selected, isTrue);
    });
  });

  group('parking a bill', () {
    /// Seat table 5, ring one item and park it, which is the move the
    /// confirmation belongs to.
    Future<void> parkATab(WidgetTester t) async {
      await t.tap(find.byKey(Key('table-tile-${mainTable.id}')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('product-10')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('hold')));
      await t.pumpAndSettle();
    }

    testWidgets('is confirmed above the plan, not over the button row',
        (t) async {
      await t.pumpWidget(app());
      await signIn(t);
      await parkATab(t);

      expect(find.byType(TableFloorScreen), findsOneWidget);
      expect(find.byKey(const Key('floor-parked-notice')), findsOneWidget);
      expect(find.text('Order parked on table 5'), findsOneWidget);
      // The old confirmation was a toast, which lands at the bottom of the screen
      // on top of the To go / Takeaway / Delivery row.
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('leaves the next order one tap away', (t) async {
      await t.pumpWidget(app());
      await signIn(t);
      await parkATab(t);

      // No waiting anything out: the button row is live the moment the floor is up.
      await t.tap(find.byKey(const Key('floor-to-go')));
      await t.pumpAndSettle();
      expect(find.byType(SellScreen), findsOneWidget);
    });

    testWidgets('and the line goes away on its own', (t) async {
      await t.pumpWidget(app());
      await signIn(t);
      await parkATab(t);

      await t.pump(const Duration(seconds: 5));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('floor-parked-notice')), findsNothing);
      // The tile turning occupied is the lasting record, not the line.
      expect(orders.held().single.tableLabel, '5');
    });
  });
}
