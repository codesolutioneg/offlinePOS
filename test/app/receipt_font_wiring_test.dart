import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/app/pos_app.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/auth/auth_service.dart';
import 'package:offline_pos/core/auth/user_store.dart';
import 'package:offline_pos/core/db/attendance_store.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/customer_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/db/shift_store.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/db/table_store.dart';
import 'package:offline_pos/core/onboarding/wizard_store.dart';
import 'package:offline_pos/core/printing/escpos.dart';
import 'package:offline_pos/core/printing/printer_discovery.dart';
import 'package:offline_pos/core/printing/printer_registry.dart';
import 'package:offline_pos/core/printing/spool_store.dart';
import 'package:offline_pos/core/sync/odoo_endpoint.dart';
import 'package:offline_pos/core/sync/odoo_wiring.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/core/sync/sync_service.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/features/sell/sell_screen.dart';
import 'package:offline_pos/features/settings/receipt_designer_screen.dart';
import 'package:offline_pos/features/tables/table_floor_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// How big a real sale prints, chosen where a manager chooses it.
///
/// The layout maths is covered in test/printing. What is covered here is the seam:
/// the size lives in a database the printing layer never reads, so if the shell
/// stops publishing it the slips quietly go back to normal and every unit test
/// still passes.
void main() {
  late Db db;
  late OrderStore orders;
  late SettingsStore settings;
  late AuditLog audit;
  late MemorySpoolStore spool;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    // The till refuses to start an order with no shift open, so a test that
    // sells opens the drawer first.
    ShiftStore(db).openShift(openingFloat: 100, cashierId: 'sara');
    orders = OrderStore(db, ownDeviceId: 'till-1');
    audit = AuditLog(db);
    spool = MemorySpoolStore();
    await AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'sara', name: 'Sara', pin: '1234', role: 'manager');
    CatalogueStore(db).replaceAll(
      categories: const [Category(id: 1, name: 'Food')],
      products: const [Product(id: 10, name: 'Pizza', price: 250, categoryId: 1)],
      groups: const [],
      productGroupIds: const {},
      paymentMethods: const [PaymentMethod(id: 1, name: 'Cash', isCash: true)],
      refreshedAt: DateTime.now().toUtc(),
    );
    // Built after the catalogue so the print profile is published from a settled
    // database, exactly as it is on a real start-up.
    settings = SettingsStore(db);
  });
  tearDown(() {
    db.close();
    // The profile is process-wide, so a test that changed it must not leave it
    // changed for the next one.
    EscPosPrintProfile.shared = EscPosPrintProfile();
  });

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
      receiptSpool: spool,
    );
  }

  Future<void> boot(WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1280, 1600));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('user-sara')));
    await t.pump();
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
    if (find.byType(TableFloorScreen).evaluate().isNotEmpty) {
      await t.pageBack();
      await t.pumpAndSettle();
    }
    await t.tap(find.byKey(const Key('wizard-skip')));
    await t.pumpAndSettle();
  }

  Future<void> sellAPizza(WidgetTester t) async {
    await t.tap(find.byKey(const Key('product-10')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('pay')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('method-1')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-payment')));
    await t.pumpAndSettle();
  }

  /// The bytes of the slip the customer would have been handed.
  Future<List<int>> saleSlip() async {
    final sale = orders.recent(limit: 1).single;
    final jobs = await spool.oldestFirst(limit: 100);
    return jobs
        .firstWhere((j) => (j.reference ?? '').startsWith(sale.uuid))
        .bytes
        .toList();
  }

  bool containsBytes(List<int> haystack, List<int> needle) {
    for (var i = 0; i + needle.length <= haystack.length; i++) {
      var hit = true;
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) {
          hit = false;
          break;
        }
      }
      if (hit) return true;
    }
    return false;
  }

  testWidgets('a till on the default profile prints what it always printed',
      (t) async {
    await boot(t);
    await sellAPizza(t);

    expect(containsBytes(await saleSlip(), const [0x1d, 0x21]), isFalse);
  });

  testWidgets('a shop set to print tall gets a tall slip', (t) async {
    settings.receiptFontProfile = 'tall';

    await boot(t);
    await sellAPizza(t);

    expect(containsBytes(await saleSlip(), const [0x1d, 0x21, 0x01]), isTrue,
        reason: 'the shell must publish the size, or the setting is dead');
  });

  testWidgets('choosing the size in the designer changes the next sale', (t) async {
    await boot(t);

    await t.tap(find.byType(DrawerButton));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-settings')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('set-receipt')));
    await t.pumpAndSettle();
    expect(find.byType(ReceiptDesignerScreen), findsOneWidget);

    await t.tap(find.byKey(const Key('t-font-large')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('save-receipt')));
    await t.pumpAndSettle();
    await t.pageBack();
    await t.pumpAndSettle();
    await t.pageBack();
    await t.pumpAndSettle();

    await sellAPizza(t);

    expect(settings.receiptFontProfile, 'large');
    // GS ! n with both nibbles at two, and a layout that shrank to match.
    expect(containsBytes(await saleSlip(), const [0x1d, 0x21, 0x11]), isTrue);
    expect(String.fromCharCodes(await saleSlip()), contains('-' * 21));
  });
}
