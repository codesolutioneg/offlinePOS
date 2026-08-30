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
import 'package:offline_pos/domain/table_preorder.dart';
import 'package:offline_pos/features/sell/sell_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// What a table opens with, on the floor of a running app.
///
/// A cover charge that only exists in a settings screen is worth nothing: what matters
/// is the line landing on the bill the moment guests sit down, priced per head, once
/// and not again when the tab is picked back up.
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
      products: const [
        Product(id: 10, name: 'Margherita', price: 250, categoryId: 1),
        Product(id: 11, name: 'Cover charge', price: 20, categoryId: 1),
        Product(id: 12, name: 'Water', price: 15, categoryId: 1),
      ],
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

  Future<void> seatTable(WidgetTester t) async {
    await t.tap(find.byKey(Key('table-tile-${table5.id}')));
    await t.pumpAndSettle();
  }



  /// Seat the table and answer the covers prompt with [guests], which is picked
  /// from a list rather than tapped straight off the dialog.
  Future<void> seatFor(WidgetTester t, int guests) async {
    await seatTable(t);
    await t.tap(find.byKey(const Key('guest-count-dropdown')));
    await t.pumpAndSettle();
    // The open menu is the last copy of the row in the tree; the button keeps an
    // offstage one that cannot be tapped.
    await t.tap(find.descendant(
        of: find.byKey(Key('guests-$guests')),
        matching: find.text('$guests')).last);
    await t.pumpAndSettle();
  }

  /// The lines on the order the cashier is now ringing.
  List<OrderLine> currentLines() => orders.held().isNotEmpty
      ? orders.held().first.lines
      : orders.drafts().first.lines;

  testWidgets('a section cover charge lands on the bill, one per guest', (t) async {
    settings.setSectionPreorders(
        'Main', const [TablePreorder(productId: 11, perGuest: true)]);

    await t.pumpWidget(app());
    await signIn(t);
    await seatFor(t, 3);

    expect(find.byType(SellScreen), findsOneWidget);
    final lines = currentLines();
    expect(lines, hasLength(1));
    expect(lines.single.name, 'Cover charge');
    expect(lines.single.quantity, 3);
  });

  testWidgets('a fixed quantity is not multiplied by the covers', (t) async {
    settings.setSectionPreorders(
        'Main', const [TablePreorder(productId: 12, quantity: 2)]);

    await t.pumpWidget(app());
    await signIn(t);
    await seatFor(t, 4);

    final lines = currentLines();
    expect(lines.single.name, 'Water');
    expect(lines.single.quantity, 2);
  });

  testWidgets('a table with its own list ignores the room', (t) async {
    settings.setSectionPreorders('Main', const [TablePreorder(productId: 11)]);
    settings.setTablePreorders(table5.id, const [TablePreorder(productId: 12)]);

    await t.pumpWidget(app());
    await signIn(t);
    await seatFor(t, 2);

    expect(currentLines().map((l) => l.name), ['Water']);
  });

  testWidgets('a table told to open with nothing opens with nothing', (t) async {
    settings.setSectionPreorders('Main', const [TablePreorder(productId: 11)]);
    settings.setTablePreorders(table5.id, const []);

    await t.pumpWidget(app());
    await signIn(t);
    await seatFor(t, 2);

    expect(currentLines(), isEmpty);
  });

  testWidgets('picking the tab back up does not charge the cover twice', (t) async {
    settings.setSectionPreorders(
        'Main', const [TablePreorder(productId: 11, perGuest: true)]);

    await t.pumpWidget(app());
    await signIn(t);
    await seatFor(t, 2);
    // Park it and walk back to the same table, the way a waiter does all night.
    await t.tap(find.byKey(const Key('hold')));
    await t.pumpAndSettle();
    await seatTable(t);

    // Recalled, not re-seated: no covers prompt and no second cover charge.
    expect(find.byKey(const Key('guest-count-prompt')), findsNothing);
    final lines = currentLines();
    expect(lines, hasLength(1));
    expect(lines.single.quantity, 2);
  });

  testWidgets('the waiter can still take the line off', (t) async {
    settings.setSectionPreorders('Main', const [TablePreorder(productId: 12)]);

    await t.pumpWidget(app());
    await signIn(t);
    await seatFor(t, 2);
    expect(currentLines(), hasLength(1));

    // An ordinary order line from the moment it is added: it comes off with the same
    // trash the waiter uses on anything else they rang by mistake.
    await t.tap(find.byIcon(Icons.delete_outline));
    await t.pumpAndSettle();

    expect(currentLines(), isEmpty);
  });

  testWidgets('a line naming a product the menu lost is skipped, not fatal', (t) async {
    settings.setSectionPreorders('Main', const [
      TablePreorder(productId: 999),
      TablePreorder(productId: 12),
    ]);

    await t.pumpWidget(app());
    await signIn(t);
    await seatFor(t, 2);

    // The table still opens, with the line that could be priced.
    expect(find.byType(SellScreen), findsOneWidget);
    expect(currentLines().map((l) => l.name), ['Water']);
  });

  testWidgets('a takeaway opens with nothing: this is a table rule', (t) async {
    settings.setSectionPreorders('Main', const [TablePreorder(productId: 11)]);

    await t.pumpWidget(app());
    await signIn(t);
    await t.tap(find.byKey(const Key('floor-takeaway')));
    await t.pumpAndSettle();

    expect(currentLines(), isEmpty);
  });
}
