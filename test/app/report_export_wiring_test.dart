import 'dart:io';

import 'package:excel/excel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/sell/sell_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// Downloading a report off a running till, and reading the shift you are standing
/// in.
///
/// The owner asked for two things a manager cannot get from a screen: a report
/// filtered to the open shift rather than to a calendar day, and any single report
/// as a workbook or a PDF carrying a proper header. Both are checked here through
/// the app, and the files are read back off disk rather than trusted.
void main() {
  late Db db;
  late OrderStore orders;
  late ShiftStore shifts;
  late SettingsStore settings;
  late AuditLog audit;
  late Directory downloads;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    orders = OrderStore(db);
    shifts = ShiftStore(db);
    settings = SettingsStore(db)..shopName = 'Nour Grill';
    audit = AuditLog(db);
    await AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'sara', name: 'Sara', pin: '1234');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');

    // A real directory for the downloads, so an exported file can be opened and
    // read rather than assumed.
    downloads = await Directory.systemTemp.createTemp('offlinepos-export');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => downloads.path);
  });
  tearDown(() async {
    db.close();
    if (downloads.existsSync()) await downloads.delete(recursive: true);
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
      shifts: shifts,
      deviceId: 'till-1',
      endpoints: OdooEndpointStore(db),
      odoo: OdooWiring(outbox: outbox),
      tables: TableStore(db),
      settings: settings,
      customers: CustomerStore(db),
      attendance: AttendanceStore(db),
      config: const TillConfig(),
    );
  }

  Order sale(double amount, {DateTime? at, OrderState state = OrderState.paid}) {
    final order = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      type: OrderType.takeaway,
      state: state,
      createdAt: at,
    )..lines.add(
        OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: amount));
    orders.save(order, announce: false);
    return order;
  }

  /// An order being rung keeps sign-in on the sell screen, which is where the
  /// navigation drawer lives.
  void draftOnTheTill() => sale(10, state: OrderState.draft);

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

  Future<void> openReports(WidgetTester t) async {
    t.state<ScaffoldState>(find
            .descendant(of: find.byType(SellScreen), matching: find.byType(Scaffold))
            .first)
        .openDrawer();
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-report')));
    await t.pumpAndSettle();
  }

  /// Pick a format off the download menu of whatever report is on screen.
  Future<void> download(WidgetTester t, String format) async {
    await t.tap(find.byKey(const Key('report-export')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('export-$format')));
    // Real file IO, so the fake clock has to be let go of for a moment. Pumped by
    // hand rather than settled: settling runs the confirmation snackbar out to its
    // own dismissal, and whether the cashier is told is part of what is checked.
    await t.pump(const Duration(milliseconds: 300));
    for (var i = 0; i < 20; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
      if (find.byType(SnackBar).evaluate().isNotEmpty) return;
    }
  }

  File exported(String extension) => downloads
      .listSync()
      .whereType<File>()
      .firstWhere((f) => f.path.endsWith('.$extension'));

  void tallWindow(WidgetTester t) {
    t.view.physicalSize = const Size(1000, 3200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

  testWidgets('the open shift is a range beside today and yesterday', (t) async {
    tallWindow(t);
    draftOnTheTill();
    // Sold on the shift before this one, then the drawer was changed over.
    final now = DateTime.now().toUtc();
    sale(500, at: now.subtract(const Duration(minutes: 20)));
    shifts.openShift(
        openingFloat: 100,
        cashierId: 'sara',
        at: now.subtract(const Duration(minutes: 10)));
    sale(60);
    sale(40);

    await t.pumpWidget(app());
    await signIn(t);
    await openReports(t);

    // Every range holds all three; the shift holds only what was rung since it
    // opened. Compared against All rather than Today, so the test does not depend
    // on which side of midnight it runs.
    await t.tap(find.byKey(const Key('range-all')));
    await t.pumpAndSettle();
    expect(find.text('3 order(s) in range'), findsOneWidget);

    await t.tap(find.byKey(const Key('range-openShift')));
    await t.pumpAndSettle();
    expect(find.text('2 order(s) in range'), findsOneWidget);
  });

  testWidgets('with no shift open there is no such range to pick', (t) async {
    tallWindow(t);
    draftOnTheTill();

    await t.pumpWidget(app());
    await signIn(t);
    await openReports(t);

    expect(find.byKey(const Key('range-today')), findsOneWidget);
    expect(find.byKey(const Key('range-openShift')), findsNothing);
  });

  testWidgets('a single report downloads as a workbook with a full header',
      (t) async {
    tallWindow(t);
    draftOnTheTill();
    shifts.openShift(openingFloat: 100, cashierId: 'sara');
    shifts.addMovement('out', 25, reason: 'Taxi for delivery', category: 'Transport');

    await t.pumpWidget(app());
    await signIn(t);
    await openReports(t);
    await t.tap(find.byKey(const Key('rep-expenses')));
    await t.pumpAndSettle();

    await download(t, 'xlsx');
    expect(find.textContaining('Saved to'), findsOneWidget);

    final book = Excel.decodeBytes(exported('xlsx').readAsBytesSync());
    final sheet = book.tables[book.tables.keys.first]!;
    String cell(int row, int col) =>
        sheet.rows[row][col]?.value?.toString() ?? '';

    // Title, then the shop, the report, the period and who ran it, then the table.
    expect(cell(0, 0), 'Expenses');
    expect([for (var r = 1; r < 6; r++) '${cell(r, 0)}=${cell(r, 1)}'], [
      'Shop=Nour Grill',
      'Report=Expenses',
      'Period=Today',
      'Run by=sara',
      startsWith('Generated='),
    ]);
    expect(cell(7, 0), 'Date');
    expect(cell(8, 2), 'Taxi for delivery');
  });

  testWidgets('the same report downloads as a PDF and as a CSV', (t) async {
    tallWindow(t);
    draftOnTheTill();
    shifts.openShift(openingFloat: 100, cashierId: 'sara');
    shifts.addMovement('out', 25, reason: 'Taxi for delivery', category: 'Transport');

    await t.pumpWidget(app());
    await signIn(t);
    await openReports(t);
    await t.tap(find.byKey(const Key('rep-expenses')));
    await t.pumpAndSettle();

    await download(t, 'pdf');
    expect(String.fromCharCodes(exported('pdf').readAsBytesSync().take(4)), '%PDF');

    await download(t, 'csv');
    final csv = exported('csv').readAsStringSync();
    expect(csv, startsWith('Expenses\nShop,Nour Grill\nReport,Expenses\n'
        'Period,Today\nRun by,sara\nGenerated,'));
    expect(csv, contains('Date,Category,Reason,Cashier,Shift,Amount'));
    expect(csv, contains('Taxi for delivery'));
  });

  testWidgets('the header follows the range the manager picked', (t) async {
    tallWindow(t);
    draftOnTheTill();
    shifts.openShift(openingFloat: 100, cashierId: 'sara');
    shifts.addMovement('out', 25, reason: 'Taxi for delivery');

    await t.pumpWidget(app());
    await signIn(t);
    await openReports(t);
    await t.tap(find.byKey(const Key('range-openShift')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('rep-expenses')));
    await t.pumpAndSettle();

    await download(t, 'csv');
    expect(exported('csv').readAsStringSync(), contains('Period,Current shift'));
  });
}
