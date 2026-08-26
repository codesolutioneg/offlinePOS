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
import 'package:offline_pos/core/db/reservation_store.dart';
import 'package:offline_pos/core/db/table_assignment_store.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/db/shift_store.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/db/table_store.dart';
import 'package:offline_pos/core/lan/lan_applier.dart';
import 'package:offline_pos/core/lan/lan_cart_board.dart';
import 'package:offline_pos/core/lan/lan_event.dart';
import 'package:offline_pos/core/lan/lan_event_log.dart';
import 'package:offline_pos/core/onboarding/wizard_id.dart';
import 'package:offline_pos/core/onboarding/wizard_store.dart';
import 'package:offline_pos/core/printing/printer_discovery.dart';
import 'package:offline_pos/core/printing/printer_registry.dart';
import 'package:offline_pos/core/sync/odoo_endpoint.dart';
import 'package:offline_pos/core/sync/odoo_wiring.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/core/sync/sync_service.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/features/auth/login_screen.dart';
import 'package:offline_pos/features/display/customer_display_screen.dart';
import 'package:offline_pos/features/sell/sell_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// The customer display as a device mode, exactly like the kitchen board: a build
/// that boots into it, shows the counter it is fed over the LAN, and can do nothing
/// else at all.
///
/// Both halves are here, because either one alone is a dead feature: a till that
/// publishes a cart nothing shows, or a screen nothing ever feeds.
void main() {
  late Db db;
  late SettingsStore settings;
  late AuditLog audit;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    // The till refuses to start an order with no shift open, so a test that
    // sells opens the drawer first.
    ShiftStore(db).openShift(openingFloat: 100, cashierId: 'sara');
    settings = SettingsStore(db);
    audit = AuditLog(db);
    CatalogueStore(db).replaceAll(
      categories: const [Category(id: 1, name: 'Food')],
      products: const [Product(id: 10, name: 'Pizza', price: 250, categoryId: 1)],
      groups: const [],
      productGroupIds: const {},
      refreshedAt: DateTime.now().toUtc(),
    );
    await AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'sara', name: 'Sara', pin: '1234');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');
  });
  tearDown(() => db.close());

  Widget app({required bool displayMode, OrderStore? orders}) {
    final outbox = Outbox(store: SqliteOutboxStore(db), senders: {});
    return PosApp(
      auth: AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit),
      users: UserStore(db),
      catalogue: CatalogueStore(db),
      orders: orders ?? OrderStore(db, ownDeviceId: 'till-1'),
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
      reservations: ReservationStore(db),
      assignments: TableAssignmentStore(db),
      config: TillConfig(displayMode: displayMode, shopName: 'Dishflow'),
    );
  }

  /// What the counter till puts on the fabric, applied here the way a display
  /// device's applier does.
  void theCounterIsRinging(List<LanCartLine> lines, double total) {
    LanApplier(
      deviceId: 'display-1',
      orders: OrderStore(db, ownDeviceId: 'display-1'),
      tables: TableStore(db),
      settings: settings,
      reservations: ReservationStore(db),
      assignments: TableAssignmentStore(db),
      log: LanEventLog(db, deviceId: 'display-1'),
    ).apply(LanEvent(
      kind: LanEventKind.cartDisplay,
      originDeviceId: 'till-2',
      seq: 1,
      recordUuid: 'till-2',
      payload: LanCartSnapshot(
        deviceId: 'till-2',
        lines: lines,
        total: total,
        at: DateTime.now().toUtc(),
      ).toMap(),
      at: DateTime.now().toUtc(),
    ));
  }

  testWidgets('a display build boots into the display, with nobody signed in',
      (t) async {
    await t.pumpWidget(app(displayMode: true));
    await t.pumpAndSettle();

    expect(find.byType(CustomerDisplayScreen), findsOneWidget);
    expect(find.byType(LoginScreen), findsNothing);
    expect(find.byType(SellScreen), findsNothing);
    // Nothing on the counter yet, so the shop's name and not a blank screen.
    expect(find.byKey(const Key('display-idle')), findsOneWidget);
    expect(find.text('Dishflow'), findsWidgets);
  });

  testWidgets('the same build without the flag still asks who is on the till',
      (t) async {
    await t.pumpWidget(app(displayMode: false));
    await t.pumpAndSettle();

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(CustomerDisplayScreen), findsNothing);
  });

  testWidgets('what the counter is ringing appears on the display', (t) async {
    await t.pumpWidget(app(displayMode: true));
    await t.pumpAndSettle();

    theCounterIsRinging(
      const [
        LanCartLine(name: 'Pizza', quantity: 1, total: 250),
        LanCartLine(name: 'Cola', quantity: 2, total: 60),
      ],
      310,
    );
    // The display reads the board on its own timer, the way the fabric writes it.
    await t.pump(const Duration(seconds: 2));

    expect(find.byKey(const Key('display-cart')), findsOneWidget);
    expect(find.text('Pizza'), findsOneWidget);
    expect(find.text('2x'), findsOneWidget);
    expect(find.byKey(const Key('display-total')), findsOneWidget);
    expect(find.text('310.00'), findsOneWidget);
  });

  testWidgets('the counter clearing takes the shopping off the screen', (t) async {
    await t.pumpWidget(app(displayMode: true));
    await t.pumpAndSettle();
    theCounterIsRinging(
        const [LanCartLine(name: 'Pizza', quantity: 1, total: 250)], 250);
    await t.pump(const Duration(seconds: 2));
    expect(find.byKey(const Key('display-cart')), findsOneWidget);

    // What a paid sale publishes: an empty counter.
    theCounterIsRinging(const [], 0);
    await t.pump(const Duration(seconds: 2));

    expect(find.byKey(const Key('display-idle')), findsOneWidget);
    expect(find.text('Pizza'), findsNothing);
  });

  testWidgets('a till that feeds a display announces its counter as it is rung',
      (t) async {
    // The other half of the wire: a selling till with the switch on.
    LanCartBoard(settings).publishing = true;
    final sent = <({LanEventKind kind, Map<String, dynamic> payload})>[];
    final orders = OrderStore(
      db,
      ownDeviceId: 'till-1',
      publish: (kind, uuid, payload) => sent.add((kind: kind, payload: payload)),
      publishesCart: () => LanCartBoard(settings).publishing,
    );

    await t.pumpWidget(app(displayMode: false, orders: orders));
    await t.tap(find.byKey(const Key('user-sara')));
    await t.pumpAndSettle();
    for (final d in '1234'.split('')) {
      await t.tap(find.byKey(Key('key-$d')));
      await t.pump();
    }
    await t.tap(find.byKey(const Key('pin-ok')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('floor-takeaway')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('product-10')));
    await t.pumpAndSettle();

    final carts =
        sent.where((e) => e.kind == LanEventKind.cartDisplay).toList();
    expect(carts, isNotEmpty,
        reason: 'a cart nothing announces is a display that never lights up');
    final last = LanCartSnapshot.fromMap(carts.last.payload);
    expect(last.lines.single.name, 'Pizza');
    expect(last.total, 250);
  });
}
