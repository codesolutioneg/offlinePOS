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
import 'package:offline_pos/features/tables/table_floor_screen.dart';

import '../db/sqlite_loader.dart';
import '../printing/strip_escpos.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// What comes out of the printer after a real sale on a real shell.
///
/// The printing layer's own tests build a receipt from an order they made up. That
/// proved the layout and proved nothing about the till: an Arabic shop reported a
/// slip it could not read while every one of those tests was green. So each of these
/// signs in, rings the sale on the floor and reads the bytes the spool caught on
/// their way to the wire.
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
    // A manager, because a discount is manager-gated and a PIN prompt in front of
    // the dialog is not what these are about.
    await AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'sara', name: 'Sara', pin: '1234', role: 'manager');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');
    CatalogueStore(db).replaceAll(
      categories: const [Category(id: 1, name: 'Food')],
      products: const [
        Product(id: 10, name: 'شاورما فراخ', price: 300, categoryId: 1),
      ],
      groups: const [],
      productGroupIds: const {},
      paymentMethods: const [PaymentMethod(id: 1, name: 'Cash', isCash: true)],
      refreshedAt: DateTime.now().toUtc(),
    );
    // A floor with more than one part, and the table the sale is rung on in the one
    // that is not the default.
    TableStore(db).add(name: '5', section: 'Terrace');
    // Built last so the print profile is published from a settled database, exactly
    // as it is on a real start-up.
    settings = SettingsStore(db);
  });
  tearDown(() {
    db.close();
    // The profile is process-wide, so a test that changed it must not leave it
    // changed for the next one.
    EscPosPrintProfile.shared = EscPosPrintProfile();
    EscPosDeferredDocs.shared.clear();
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
      config: const TillConfig(),
    );
  }

  Future<void> signIn(WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1280, 1600));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('user-sara')));
    await t.pumpAndSettle();
    for (final d in '1234'.split('')) {
      await t.tap(find.byKey(Key('key-$d')));
      await t.pump();
    }
    await t.tap(find.byKey(const Key('pin-ok')));
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 50));
      if (find.byType(TableFloorScreen).evaluate().isNotEmpty) break;
    }
    await t.pumpAndSettle();
  }

  /// Sit at table 5, the way a waiter does: off the floor, not out of a text field.
  Future<void> sitAtTableFive(WidgetTester t) async {
    final tile = find.byWidgetPredicate(
        (w) => w is InkWell && '${w.key}'.startsWith('[<\'table-tile-'));
    await t.tap(tile.first);
    await t.pumpAndSettle();
    expect(find.byType(SellScreen), findsOneWidget);
  }

  Future<void> ringAndPay(WidgetTester t) async {
    await t.tap(find.byKey(const Key('product-10')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('pay')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('method-1')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-payment')));
    await t.pumpAndSettle();
  }

  /// The bytes of the slip the customer would have been handed. Nothing answered on
  /// the LAN, so the spool caught the job on its way out, rasterised exactly as it
  /// would have reached the printer.
  ///
  /// Waited for rather than read straight away, and waited for through [runAsync]:
  /// the screen that took the money does not await the print, and the print draws a
  /// picture, which is real work that a pumped frame does not advance. That the
  /// receipt lands here at all is the point, since the sale was already on disk.
  Future<List<int>> saleSlip(WidgetTester t) async {
    final sale = orders.recent(limit: 1).single;
    for (var i = 0; i < 60; i++) {
      final hit = (await spool.oldestFirst(limit: 100))
          .where((j) => (j.reference ?? '').startsWith(sale.uuid));
      if (hit.isNotEmpty) return hit.first.bytes.toList();
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
    }
    fail('the receipt never reached the spool');
  }

  testWidgets('an Arabic name reaches the printer as dots, not question marks',
      (t) async {
    settings.language = 'ar';

    await signIn(t);
    await sitAtTableFive(t);
    await ringAndPay(t);

    final slip = await saleSlip(t);
    expect(printedBands(slip), isNotEmpty,
        reason: 'the till never rendered the name, so the paper says nothing');
    expect(strippedText(slip).contains('?'), isFalse,
        reason: 'a fallback character means the band did not replace the line');
  });

  testWidgets('every rendered line ends, so the next one starts on its own',
      (t) async {
    settings.language = 'ar';

    await signIn(t);
    await sitAtTableFive(t);
    await ringAndPay(t);

    // A printer that does not return to the start of the line after a raster image
    // draws whatever follows into the side of it. Every band has to be terminated.
    final slip = await saleSlip(t);
    var checked = 0;
    var i = 0;
    while (i < slip.length) {
      if (i + 8 <= slip.length &&
          slip[i] == 0x1d &&
          slip[i + 1] == 0x76 &&
          slip[i + 2] == 0x30) {
        final widthBytes = slip[i + 4] | (slip[i + 5] << 8);
        final height = slip[i + 6] | (slip[i + 7] << 8);
        final after = i + 8 + widthBytes * height;
        expect(after < slip.length && slip[after] == 0x0a, isTrue,
            reason: 'the band at $i is not followed by a line end');
        checked++;
        i = after;
        continue;
      }
      i++;
    }
    expect(checked, greaterThan(0));
  });

  testWidgets('a Latin till still prints its Arabic, because the shop asked',
      (t) async {
    // The rendering toggle follows the till language by default and a manager can
    // overrule it. An English-language till in an Arabic shop is a real setup, and
    // turning it on there has to work.
    settings.receiptArabicRaster = true;

    await signIn(t);
    await sitAtTableFive(t);
    await ringAndPay(t);

    expect(printedBands(await saleSlip(t)), isNotEmpty);
  });

  testWidgets('the slip says which part of the floor the table is in', (t) async {
    await signIn(t);
    await sitAtTableFive(t);
    await ringAndPay(t);

    expect(strippedText(await saleSlip(t)), contains('Terrace - Table 5'));
  });

  testWidgets('money off prints the money, and no rate that contradicts it',
      (t) async {
    settings.allowAmountDiscount = true;

    await signIn(t);
    await sitAtTableFive(t);
    await t.tap(find.byKey(const Key('product-10')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('discount')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('discount-mode-amount')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('discount-value')), '50');
    await t.tap(find.byKey(const Key('apply-discount')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('pay')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('method-1')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-payment')));
    await t.pumpAndSettle();

    // 50 off 300 is 16.666...%, which prints as 16.7 and would then be 50.10 of the
    // bill. The money is what the customer was given, so the money is what prints.
    final text = strippedText(await saleSlip(t));
    expect(text, contains('Discount'));
    expect(text, contains('-50.00'));
    expect(text, isNot(contains('16.7%')));
  });

  testWidgets('a rate typed as a rate still prints on the slip', (t) async {
    await signIn(t);
    await sitAtTableFive(t);
    await t.tap(find.byKey(const Key('product-10')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('discount')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('discount-value')), '10');
    await t.tap(find.byKey(const Key('apply-discount')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('pay')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('method-1')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-payment')));
    await t.pumpAndSettle();

    final text = strippedText(await saleSlip(t));
    expect(text, contains('Discount 10%'));
    expect(text, contains('-30.00'));
  });
}
