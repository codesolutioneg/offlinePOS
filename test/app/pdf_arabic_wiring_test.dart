import 'dart:io';

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
import 'pdf_bytes.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// An Arabic dish name coming out of the exporter as a dish name.
///
/// The shop's menu is Arabic and its reports were not: the PDF exporter drew in
/// the pdf package's built-in Helvetica, which has no Arabic glyph, so a name came
/// out blank and the only trace was a line in the build log. A test that only
/// asserts the export did not throw would have passed all the way through that,
/// which is how it survived this long. So the bytes are opened here: the font the
/// document actually embeds, and the characters that font was actually asked for.
///
/// Each case also leaves its PDF under build/pdf-arabic/ so a human can open the
/// page and look at it, because glyphs are ultimately something you look at.
void main() {
  late Db db;
  late OrderStore orders;
  late SettingsStore settings;
  late AuditLog audit;
  late Directory downloads;

  /// Where a person can go and open what the test produced.
  final keep = Directory('build/pdf-arabic');

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    orders = OrderStore(db);
    settings = SettingsStore(db)..shopName = 'Nour Grill';
    audit = AuditLog(db);
    await AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'sara', name: 'Sara', pin: '1234');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');

    downloads = await Directory.systemTemp.createTemp('offlinepos-pdf');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => downloads.path);
    keep.createSync(recursive: true);
  });
  tearDown(() async {
    db.close();
    // Windows holds the export's handle for a moment after the write returns, and
    // a temp directory the OS is still finishing with is not a test failure.
    for (var attempt = 0; attempt < 5; attempt++) {
      if (!downloads.existsSync()) return;
      try {
        await downloads.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
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
      config: const TillConfig(),
    );
  }

  /// One paid order of [name], priced so the revenue column reads exactly
  /// [quantity] x [unitPrice] to two places.
  void sale(String name, {double quantity = 1, double unitPrice = 75}) {
    orders.save(
      Order(
        deviceId: 'till-1',
        cashierId: 'sara',
        type: OrderType.takeaway,
        state: OrderState.paid,
      )..lines.add(OrderLine(
          productId: 1, name: name, quantity: quantity, unitPrice: unitPrice)),
      announce: false,
    );
  }

  /// An order still being rung keeps sign-in on the sell screen, which is where
  /// the navigation drawer lives.
  void draftOnTheTill() => orders.save(
        Order(
          deviceId: 'till-1',
          cashierId: 'sara',
          type: OrderType.takeaway,
          state: OrderState.draft,
        )..lines.add(
            OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 10)),
        announce: false,
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

  Future<void> openReports(WidgetTester t) async {
    t.state<ScaffoldState>(find
            .descendant(of: find.byType(SellScreen), matching: find.byType(Scaffold))
            .first)
        .openDrawer();
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-report')));
    await t.pumpAndSettle();
  }

  Future<void> download(WidgetTester t, String format) async {
    await t.tap(find.byKey(const Key('report-export')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('export-$format')));
    // Real file IO and a real font read off the asset bundle, so the fake clock
    // has to be let go of for a moment.
    await t.pump(const Duration(milliseconds: 300));
    for (var i = 0; i < 40; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
      if (find.byType(SnackBar).evaluate().isNotEmpty) return;
    }
  }

  /// Downloads the best-sellers report and hands back its bytes, keeping a copy
  /// under build/ named [saveAs] for anyone who wants to look at the page.
  Future<List<int>> exportTopProducts(WidgetTester t, String saveAs) async {
    t.view.physicalSize = const Size(1000, 3200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);

    await t.pumpWidget(app());
    await signIn(t);
    await openReports(t);
    await t.tap(find.byKey(const Key('rep-top')));
    await t.pumpAndSettle();
    await download(t, 'pdf');

    // The file itself rather than the confirmation on screen: the message is
    // translated, and one of these cases runs the till in Arabic.
    final written =
        downloads.listSync().whereType<File>().where((f) => f.path.endsWith('.pdf'));
    expect(written, hasLength(1),
        reason: 'the export has to have reached disk before its bytes mean anything');
    final bytes = written.single.readAsBytesSync();
    File('${keep.path}/$saveAs').writeAsBytesSync(bytes);
    return bytes;
  }

  testWidgets('an Arabic dish name is embedded in the PDF as Arabic', (t) async {
    draftOnTheTill();
    sale('كشري بالحمص', quantity: 2, unitPrice: 75);
    sale('Pizza', unitPrice: 250.5);

    final pdf = await exportTopProducts(t, 'top-products-english-ui.pdf');
    final doc = PdfBytes(pdf);

    expect(doc.isPdf, isTrue);
    // A font of our own is in the file, and the Latin-only one that cannot draw
    // any of this is not.
    expect(doc.embedsFontFile, isTrue,
        reason: 'no embedded font means the page fell back to the built-in one');
    expect(doc.baseFonts.every((f) => f.contains('Cairo')), isTrue,
        reason: 'the document draws in ${doc.baseFonts}');
    expect(doc.mentions('Helvetica'), isFalse);

    // The glyphs themselves. Every character the document asked its font for is
    // listed in the font's own character map, so this is the page's own account of
    // what it drew, not ours.
    final arabic = doc.mappedCharacters
        .where((c) => c >= 0x0600 && c <= 0x06ff || c >= 0xfb50 && c <= 0xfeff);
    expect(arabic.length, greaterThanOrEqualTo(8),
        reason: 'the dish name has ten letters and the page drew none of them');
    // All of them shaped: Arabic letters join, and a page that embedded the raw
    // U+06xx forms would print ten unconnected stumps rather than a word.
    expect(arabic.every((c) => c >= 0xfe70 && c <= 0xfefc), isTrue,
        reason: 'unjoined letter forms in the font: $arabic');
  });

  testWidgets('the money beside an Arabic name still reads left to right',
      (t) async {
    draftOnTheTill();
    sale('كشري بالحمص', quantity: 2, unitPrice: 75);
    sale('Pizza', unitPrice: 250.5);

    final doc = PdfBytes(await exportTopProducts(t, 'top-products-amounts.pdf'));

    // Both amounts, digit for digit and in order. A number caught by the
    // right-to-left pass would come back as 00.051.
    expect(doc.drawnRuns, contains('150.00'));
    expect(doc.drawnRuns, contains('250.50'));
    expect(doc.drawnRuns.any((s) => s.contains('00.051')), isFalse);
    // The English column headers are still English words in the right order.
    expect(doc.drawnRuns, contains('Product'));
    expect(doc.drawnRuns, contains('Revenue'));
  });

  testWidgets('a report run in Arabic has an Arabic header on the page', (t) async {
    settings.language = 'ar';
    draftOnTheTill();
    sale('كشري بالحمص', quantity: 2, unitPrice: 75);

    final doc = PdfBytes(await exportTopProducts(t, 'top-products-arabic-ui.pdf'));

    expect(doc.embedsFontFile, isTrue);
    // 'أفضل المنتجات' is the report's own title, and the shop and period labels
    // under it are Arabic too, so the whole header block had to be drawn in the
    // embedded font rather than only the rows.
    final shaped =
        doc.drawnRuns.where((s) => s.runes.any((c) => c >= 0xfe70 && c <= 0xfefc));
    expect(shaped.length, greaterThanOrEqualTo(6),
        reason: 'the title and the header block are Arabic as well as the rows');
    // The stamp under the header is a date, and a date must not come back
    // rearranged because the page around it turned round.
    expect(doc.drawnRuns.any((s) => RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s)),
        isTrue);
  });

  testWidgets('a Latin-only report is the file it always was', (t) async {
    draftOnTheTill();
    sale('Pizza', unitPrice: 250.5);

    final doc = PdfBytes(await exportTopProducts(t, 'top-products-latin.pdf'));

    // Nothing changed for the shop that never types Arabic: no font is carried in
    // the document and the page is still drawn in the package's built-in one.
    expect(doc.isPdf, isTrue);
    expect(doc.embedsFontFile, isFalse,
        reason: 'a Latin report should not have grown an embedded typeface');
    expect(doc.mentions('Helvetica'), isTrue);
  });
}
