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

/// The floor of a running app: where the sections are drawn, what a table tap
/// opens, which order types the shop offers at all, and recalling the bill parked
/// on a table by tapping it.
void main() {
  late Db db;
  late OrderStore orders;
  late SettingsStore settings;
  late TableStore tables;
  late PosTable table5;
  late AuditLog audit;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    orders = OrderStore(db);
    settings = SettingsStore(db);
    tables = TableStore(db);
    audit = AuditLog(db);
    table5 = tables.add(name: '5', seats: 4);
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
      if (find.byType(SellScreen).evaluate().isNotEmpty) break;
    }
    await t.pumpAndSettle();
  }

  /// Back to the floor from the sell screen, the way a cashier gets there.
  Future<void> openFloor(WidgetTester t) async {
    t.state<ScaffoldState>(find
            .descendant(of: find.byType(SellScreen), matching: find.byType(Scaffold))
            .first)
        .openDrawer();
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-tables')));
    await t.pumpAndSettle();
  }

  Future<void> tapTable(WidgetTester t) async {
    await t.tap(find.byKey(Key('table-tile-${table5.id}')));
    await t.pumpAndSettle();
  }

  group('the sections', () {
    testWidgets('are drawn beside the plan, with what each room is holding',
        (t) async {
      await t.pumpWidget(app());
      await signIn(t);

      expect(find.byType(TableFloorScreen), findsOneWidget);
      // The rail says how many of the room's tables are busy; the top strip has
      // never carried a count, so this is what tells the two apart.
      expect(
          find.descendant(
              of: find.byKey(const Key('section-main')), matching: find.text('0/1')),
          findsOneWidget);
    });

    testWidgets('go back above the plan when the shop says so', (t) async {
      settings.floorSectionsSide = false;
      await t.pumpWidget(app());
      await signIn(t);

      expect(find.byKey(const Key('section-main')), findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(const Key('section-main')), matching: find.text('0/1')),
          findsNothing);
    });
  });

  group('to go', () {
    testWidgets('is seated at a table and rung as its own type', (t) async {
      await t.pumpWidget(app());
      await signIn(t);

      // Say what is being seated, then seat it.
      await t.tap(find.byKey(const Key('seat-as-togo')));
      await t.pumpAndSettle();
      await tapTable(t);

      expect(find.byType(SellScreen), findsOneWidget);
      final chip = t.widget<ChoiceChip>(find.byKey(const Key('order-type-togo')));
      expect(chip.selected, isTrue);
      // It holds the floor like a dine-in, and says which table on the bill.
      expect(find.widgetWithText(ActionChip, 'Table 5'), findsOneWidget);

      await t.tap(find.byKey(const Key('product-10')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('hold')));
      await t.pumpAndSettle();

      final parked = orders.held().single;
      expect(parked.type, OrderType.toGo);
      expect(parked.tableLabel, '5');
      // Covers belong to a bill eaten at the table; a to-go takes none.
      expect(parked.guestCount, isNull);
      // The server is told the takeaway it is, rather than a label it has never
      // seen, while the till keeps the distinction.
      expect(parked.toServerPayload()['order_type'], 'takeaway');
      expect(parked.toMap()['order_type'], 'toGo');
    });

    testWidgets('starts without a table straight from the floor', (t) async {
      await t.pumpWidget(app());
      await signIn(t);

      await t.tap(find.byKey(const Key('floor-to-go')));
      await t.pumpAndSettle();

      final chip = t.widget<ChoiceChip>(find.byKey(const Key('order-type-togo')));
      expect(chip.selected, isTrue);
      // Offered a table rather than nagged for one: it is optional here.
      expect(find.widgetWithText(ActionChip, 'Table'), findsOneWidget);
    });
  });

  group('what the shop offers', () {
    testWidgets('a shop that does not deliver offers it to nobody', (t) async {
      settings.setShopOrderType(OrderType.delivery, false);
      await t.pumpWidget(app());
      await signIn(t);

      expect(find.byKey(const Key('floor-delivery')), findsNothing);
      expect(find.byKey(const Key('floor-takeaway')), findsOneWidget);

      await tapTable(t);
      expect(find.byKey(const Key('order-type-delivery')), findsNothing);
      expect(find.byKey(const Key('order-type-takeaway')), findsOneWidget);
    });

    testWidgets('the shop rule wins over a role that still allows the type',
        (t) async {
      // The role may ring everything; the shop has stopped taking them.
      settings.setRoleOrderType('cashier', OrderType.toGo, true);
      settings.setShopOrderType(OrderType.toGo, false);
      await t.pumpWidget(app());
      await signIn(t);

      expect(find.byKey(const Key('floor-to-go')), findsNothing);
      // One kind of seating left, so nothing to choose between.
      expect(find.byKey(const Key('seat-as-togo')), findsNothing);
      expect(find.byKey(const Key('seat-as-dinein')), findsNothing);
    });

    testWidgets('a role narrowed inside what the shop offers still is', (t) async {
      settings.setRoleOrderType('cashier', OrderType.delivery, false);
      await t.pumpWidget(app());
      await signIn(t);

      expect(find.byKey(const Key('floor-delivery')), findsNothing);
      expect(find.byKey(const Key('floor-to-go')), findsOneWidget);
    });
  });

  group('recalling a parked bill', () {
    testWidgets('tapping the table brings the held order back', (t) async {
      await t.pumpWidget(app());
      await signIn(t);

      await tapTable(t);
      await t.tap(find.byKey(const Key('product-10')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('hold')));
      await t.pumpAndSettle();
      final parked = orders.held().single;
      expect(find.byKey(Key('line-${parked.lines.single.uuid}')), findsNothing);

      await openFloor(t);
      // The table reads as busy, and the tap opens what is on it.
      expect(find.text('Free'), findsNothing);
      await tapTable(t);

      expect(find.byType(SellScreen), findsOneWidget);
      expect(find.byKey(Key('line-${parked.lines.single.uuid}')), findsOneWidget);
      expect(orders.held(), isEmpty);
      expect(orders.byUuid(parked.uuid)!.state, OrderState.draft);
    });

    testWidgets('a to-go parked on a table is recalled the same way', (t) async {
      await t.pumpWidget(app());
      await signIn(t);

      await t.tap(find.byKey(const Key('seat-as-togo')));
      await t.pumpAndSettle();
      await tapTable(t);
      await t.tap(find.byKey(const Key('product-10')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('hold')));
      await t.pumpAndSettle();
      final parked = orders.held().single;

      await openFloor(t);
      await tapTable(t);

      expect(find.byKey(Key('line-${parked.lines.single.uuid}')), findsOneWidget);
      // Recalled as what it was rung as, not as the seating the selector shows.
      final chip = t.widget<ChoiceChip>(find.byKey(const Key('order-type-togo')));
      expect(chip.selected, isTrue);
    });

    testWidgets('the covers prompt never stands in front of a parked bill',
        (t) async {
      settings.askGuestCount = true;
      await t.pumpWidget(app());
      await signIn(t);

      await tapTable(t);
      await t.tap(find.byKey(const Key('guests-2')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('product-10')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('hold')));
      await t.pumpAndSettle();
      final parked = orders.held().single;

      await openFloor(t);
      await tapTable(t);

      expect(find.byKey(const Key('guest-count-prompt')), findsNothing);
      expect(find.byKey(Key('line-${parked.lines.single.uuid}')), findsOneWidget);
    });
  });
}
