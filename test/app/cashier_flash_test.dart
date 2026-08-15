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
import 'package:offline_pos/features/shift/shift_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// Settling one cashier out of a shift two people worked.
///
/// It goes on paper through the same report path the X read uses, so nothing here
/// is a second print pipeline: nothing prints on this till, so the flash lands in
/// the spool, which is how a test reads what the printer would have produced.
void main() {
  late Db db;
  late OrderStore orders;
  late ShiftStore shifts;
  late AuditLog audit;
  late MemorySpoolStore spool;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    orders = OrderStore(db, ownDeviceId: 'till-1');
    shifts = ShiftStore(db);
    audit = AuditLog(db);
    spool = MemorySpoolStore();
    SettingsStore(db);
    shifts.openShift(openingFloat: 100, cashierId: 'sara');
    await AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'sara', name: 'Sara', pin: '1234', role: 'manager');
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
      shifts: shifts,
      deviceId: 'till-1',
      endpoints: OdooEndpointStore(db),
      odoo: OdooWiring(outbox: outbox),
      tables: TableStore(db),
      settings: SettingsStore(db),
      customers: CustomerStore(db),
      attendance: AttendanceStore(db),
      receiptSpool: spool,
      config: const TillConfig(),
    );
  }

  void sale(String cashierId, double amount) => orders.save(
        Order(
          deviceId: 'till-1',
          cashierId: cashierId,
          lines: [
            OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: amount)
          ],
          payments: [
            OrderPayment(methodId: 1, amount: amount, label: 'Cash'),
          ],
        )..state = OrderState.paid,
      );

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

  Future<void> openShiftScreen(WidgetTester t) async {
    await t.tap(find.byKey(const Key('floor-takeaway')));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Open navigation menu'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-shift')));
    await t.pumpAndSettle();
    expect(find.byType(ShiftScreen), findsOneWidget);
  }

  testWidgets('one cashier is flashed out of a shift two people worked',
      (t) async {
    sale('sara', 40);
    sale('omar', 60);

    await t.pumpWidget(app());
    await signIn(t);
    await openShiftScreen(t);

    await t.tap(find.byKey(const Key('cashier-flash')));
    await t.pumpAndSettle();
    // Both names, biggest taker first.
    expect(find.byKey(const Key('flash-omar')), findsOneWidget);
    expect(find.byKey(const Key('flash-sara')), findsOneWidget);

    await t.tap(find.byKey(const Key('flash-omar')));
    await t.pumpAndSettle();

    final jobs = await spool.oldestFirst(limit: 10);
    final flash = jobs
        .where((j) => (j.reference ?? '').startsWith('shift-Cashier flash - omar'))
        .toList();
    expect(flash, hasLength(1),
        reason: 'the flash must go out through the report path the X read uses');
    final paper = String.fromCharCodes(flash.single.bytes);
    expect(paper, contains('Cashier flash - omar'));
    expect(paper, contains('60.00'));
    // Only that cashier's takings, not the whole till's.
    expect(paper.contains('100.00'), isFalse);
    expect(find.text('Cashier flash sent to printer'), findsOneWidget);
  });

  testWidgets('a shift nobody has rung on says so instead of printing', (t) async {
    await t.pumpWidget(app());
    await signIn(t);
    await openShiftScreen(t);

    await t.tap(find.byKey(const Key('cashier-flash')));
    await t.pumpAndSettle();

    expect(find.text('No sales in this shift yet'), findsOneWidget);
    expect(await spool.oldestFirst(limit: 10), isEmpty);
  });
}
