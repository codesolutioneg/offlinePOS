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

/// Seating a table on the floor of a running app, with the covers prompt off (the
/// one-cashier shop that must see no new taps) and on.
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
    // The till refuses to start an order with no shift open, so a test that
    // sells opens the drawer first.
    ShiftStore(db).openShift(openingFloat: 100, cashierId: 'sara');
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

  Future<void> seatTable(WidgetTester t) async {
    await t.tap(find.byKey(Key('table-tile-${table5.id}')));
    await t.pumpAndSettle();
  }

  /// The covers on the order the cashier is now ringing, read off the chip.
  String guestChipLabel(WidgetTester t) => t
      .widget<Text>(find.descendant(
          of: find.byKey(const Key('guests')), matching: find.byType(Text)))
      .data!;

  testWidgets('off by default: seating a table is still one tap', (t) async {
    await t.pumpWidget(app());
    await signIn(t);

    await seatTable(t);

    expect(find.byKey(const Key('guest-count-prompt')), findsNothing);
    expect(find.byType(SellScreen), findsOneWidget);
    // Seeded from the table itself, exactly as before.
    expect(guestChipLabel(t), '4 guests');
  });

  testWidgets('on: the covers are asked for and land on the order', (t) async {
    settings.askGuestCount = true;
    await t.pumpWidget(app());
    await signIn(t);

    await seatTable(t);
    expect(find.byKey(const Key('guest-count-prompt')), findsOneWidget);
    await t.tap(find.byKey(const Key('guests-2')));
    await t.pumpAndSettle();

    expect(guestChipLabel(t), '2 guests');
    // Ring something and park it: the covers travel with the bill.
    await t.tap(find.byKey(const Key('product-10')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('hold')));
    await t.pumpAndSettle();
    expect(orders.held().single.guestCount, 2);
  });

  testWidgets('backing out of the prompt seats nobody', (t) async {
    settings.askGuestCount = true;
    await t.pumpWidget(app());
    await signIn(t);

    await seatTable(t);
    await t.tap(find.byKey(const Key('guests-cancel')));
    await t.pumpAndSettle();

    // Still on the floor, with no table taken and no order started.
    expect(find.byType(TableFloorScreen), findsOneWidget);
    expect(orders.held(), isEmpty);
    expect(orders.drafts().where((o) => o.tableLabel != null), isEmpty);
  });

  testWidgets('recalling a tab that is already open asks nothing', (t) async {
    settings.askGuestCount = true;
    await t.pumpWidget(app());
    await signIn(t);
    // Seat it, ring it, park it.
    await seatTable(t);
    await t.tap(find.byKey(const Key('guests-3')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('product-10')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('hold')));
    await t.pumpAndSettle();

    // Back to the floor and onto the same table: the covers are already known.
    t.state<ScaffoldState>(find
            .descendant(of: find.byType(SellScreen), matching: find.byType(Scaffold))
            .first)
        .openDrawer();
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-tables')));
    await t.pumpAndSettle();
    await seatTable(t);

    expect(find.byKey(const Key('guest-count-prompt')), findsNothing);
    expect(guestChipLabel(t), '3 guests');
  });
}
