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
import 'package:offline_pos/core/printing/spool_store.dart';
import 'package:offline_pos/core/sync/odoo_endpoint.dart';
import 'package:offline_pos/core/sync/odoo_wiring.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/core/sync/sync_service.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/sell/sell_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

/// No printer answers, which is the interesting case: the bill must land in the
/// spool rather than failing the waiter's tap.
class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// The bill printed from a real app shell, with nothing on the network and nothing
/// listening on the LAN: exactly a shop whose line is down.
void main() {
  late Db db;
  late OrderStore orders;
  late MemorySpoolStore spool;
  late AuditLog audit;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    // The till refuses to start an order with no shift open, so a test that
    // sells opens the drawer first.
    ShiftStore(db).openShift(openingFloat: 100, cashierId: 'sara');
    orders = OrderStore(db);
    spool = MemorySpoolStore();
    audit = AuditLog(db);
    await AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'sara', name: 'Sara', pin: '1234');
    // The first-sale coach marks would sit over the till on a fresh install; this
    // cashier has seen them.
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');
  });
  tearDown(() => db.close());

  Widget app() {
    final outbox = Outbox(store: SqliteOutboxStore(db), senders: {});
    return PosApp(
      auth: AuthService(
          users: UserStore(db), hasher: FakePinHasher(), audit: audit),
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
      receiptSpool: spool,
      wizards: WizardStore(db),
      shifts: ShiftStore(db),
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

  /// A tab already on the till, so signing in lands on the order rather than on the
  /// floor plan.
  Order draftOnTheTill() {
    final order = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      type: OrderType.dineIn,
      tableLabel: '5',
    )..lines.add(OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 100));
    orders.save(order, announce: false);
    return order;
  }

  Future<void> signIn(WidgetTester t) async {
    await t.tap(find.byKey(const Key('user-sara')));
    await t.pumpAndSettle();
    for (final d in '1234'.split('')) {
      await t.tap(find.byKey(Key('key-$d')));
      await t.pump();
    }
    await t.tap(find.byKey(const Key('pin-ok')));
    // The key derivation resolves off the frame pipeline, so give the microtask
    // queue real time rather than trusting a single settle.
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 50));
      if (find.byType(SellScreen).evaluate().isNotEmpty) break;
    }
    await t.pumpAndSettle();
  }

  testWidgets('a bill printed with the printer down is spooled under its own reference',
      (t) async {
    final order = draftOnTheTill();
    await t.pumpWidget(app());
    await signIn(t);
    expect(find.byType(SellScreen), findsOneWidget);

    await t.tap(find.byKey(const Key('print-bill')));
    await t.pumpAndSettle();

    final held = await spool.oldestFirst();
    expect(held, hasLength(1));
    expect(held.single.reference, startsWith('bill-${order.uuid}-'));
    // The bill is what got spooled, not a sale slip.
    expect(String.fromCharCodes(held.single.bytes), contains('BILL'));

    // Paper and an audit entry, and nothing else: no tender, no push, no state move.
    expect(audit.recent(event: 'bill.printed').single['detail'], order.uuid);
    expect(orders.byUuid(order.uuid)!.state, OrderState.draft);
    expect(orders.byUuid(order.uuid)!.payments, isEmpty);
    expect(SqliteOutboxStore(db).pendingCount, 0);
  });

  testWidgets('asking twice spools two copies rather than folding them into one',
      (t) async {
    draftOnTheTill();
    await t.pumpWidget(app());
    await signIn(t);

    await t.tap(find.byKey(const Key('print-bill')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('print-bill')));
    await t.pumpAndSettle();

    expect(await spool.oldestFirst(), hasLength(2));
  });
}
