// Test-only. Drives the real app on the Linux embedder through every major
// screen and writes a PNG per stop into SHOT_DIR, so the whole till can be
// looked at after a design change rather than screen by screen. Run it through
// tool/run_shots.sh, which supplies the display, the dbus session and the
// unlocked keyring the app expects.
//
// Not a golden test: nothing fails on a pixel difference. It exists so a human
// can see what the till actually looks like, which the widget tests cannot show
// because they draw every glyph as a box.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
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

import '../test/db/sqlite_loader.dart';
import '../test/ui/fake_pin_hasher.dart';

/// The app is pumped under this boundary because the root render view cannot be
/// captured directly. Dialogs, sheets and menus live in the app's own overlay,
/// which is inside the boundary, so they appear in the shot.
final GlobalKey shotKey = GlobalKey();

/// Never touch the network from a screenshot run: a real scan stalls the shot.
class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async =>
      const [];
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Db db;
  late TableStore tables;
  late List<PosTable> floor;
  late AuditLog audit;

  final dir = Directory(Platform.environment['SHOT_DIR'] ?? '/tmp/shots-tour');

  /// Pump a bounded number of frames rather than pumpAndSettle. The running app
  /// keeps a live connectivity badge on screen, so frames never stop being
  /// scheduled and pumpAndSettle would wait for a quiet tree that never comes.
  Future<void> settle(WidgetTester t, {int frames = 40}) async {
    for (var i = 0; i < frames; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
  }

  setUpAll(() {
    useSystemSqlite();
    dir.createSync(recursive: true);
  });

  setUp(() async {
    db = Db.open(':memory:');
    ShiftStore(db).openShift(openingFloat: 500, cashierId: 'sara');
    audit = AuditLog(db);
    tables = TableStore(db);
    floor = [
      tables.add(name: '1', seats: 2),
      tables.add(name: '2', seats: 4),
      tables.add(name: '3', seats: 4),
      tables.add(name: '5', seats: 8),
      tables.add(name: 'B1', seats: 2),
    ];
    // A menu that looks like a shop's, so the tour photographs a working till
    // rather than a one-product demo.
    CatalogueStore(db).replaceAll(
      categories: const [
        Category(id: 1, name: 'Pizza'),
        Category(id: 2, name: 'Burgers'),
        Category(id: 3, name: 'Drinks'),
        Category(id: 4, name: 'Desserts'),
      ],
      products: const [
        Product(id: 10, name: 'Margherita', price: 250, categoryId: 1),
        Product(id: 11, name: 'Pepperoni', price: 290, categoryId: 1),
        Product(id: 12, name: 'Quattro Formaggi', price: 320, categoryId: 1),
        Product(id: 13, name: 'Veggie Supreme', price: 270, categoryId: 1),
        Product(id: 20, name: 'Classic Burger', price: 180, categoryId: 2),
        Product(id: 21, name: 'Cheese Burger', price: 200, categoryId: 2),
        Product(id: 22, name: 'Double Smash', price: 260, categoryId: 2),
        Product(id: 30, name: 'Cola', price: 40, categoryId: 3),
        Product(id: 31, name: 'Fresh Orange', price: 70, categoryId: 3),
        Product(id: 32, name: 'Water', price: 20, categoryId: 3),
        Product(id: 40, name: 'Cheesecake', price: 120, categoryId: 4),
        Product(id: 41, name: 'Molten Cake', price: 140, categoryId: 4),
      ],
      groups: const [
        ModifierGroup(
          id: 1,
          name: 'Size',
          minSelection: 1,
          maxSelection: 1,
          required: true,
          modifiers: [
            Modifier(id: 101, groupId: 1, name: 'Small', price: 0),
            Modifier(id: 102, groupId: 1, name: 'Medium', price: 20),
            Modifier(id: 103, groupId: 1, name: 'Large', price: 40),
          ],
        ),
        ModifierGroup(
          id: 2,
          name: 'Extras',
          maxSelection: 3,
          modifiers: [
            Modifier(id: 201, groupId: 2, name: 'Extra Cheese', price: 10),
            Modifier(id: 202, groupId: 2, name: 'Bacon', price: 15),
            Modifier(id: 203, groupId: 2, name: 'Mushrooms', price: 0),
          ],
        ),
      ],
      productGroupIds: const {
        10: [1, 2],
      },
      paymentMethods: const [
        PaymentMethod(id: 1, name: 'Cash', isCash: true),
        PaymentMethod(id: 2, name: 'Card'),
        PaymentMethod(id: 3, name: 'Wallet'),
      ],
      refreshedAt: DateTime.now().toUtc(),
    );
    // A manager, so the gated doors on the tour (reports, settings) open
    // without an approval dialog standing in the shot.
    await AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'sara', name: 'Sara Ahmed', pin: '1234', role: 'manager');
    await AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'omar', name: 'Omar Khaled', pin: '5678');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');
    // The covers prompt has its own screenshot suite; the tour goes straight to
    // the counter.
    SettingsStore(db).askGuestCount = false;
  });

  tearDown(() => db.close());

  Widget app() {
    final outbox = Outbox(store: SqliteOutboxStore(db), senders: {});
    return PosApp(
      auth: AuthService(
          users: UserStore(db), hasher: FakePinHasher(), audit: audit),
      users: UserStore(db),
      catalogue: CatalogueStore(db),
      orders: OrderStore(db),
      outbox: outbox,
      audit: audit,
      sync: SyncService(
        outbox: outbox,
        catalogue: CatalogueStore(db),
        outboxStore: SqliteOutboxStore(db),
        deviceId: 'till-1',
        appVersion: 'shots',
      ),
      outboxStore: SqliteOutboxStore(db),
      printers: PrinterRegistry(discovery: _NoPrinters()),
      wizards: WizardStore(db),
      shifts: ShiftStore(db),
      deviceId: 'till-1',
      endpoints: OdooEndpointStore(db),
      odoo: OdooWiring(outbox: outbox),
      tables: tables,
      settings: SettingsStore(db),
      customers: CustomerStore(db),
      attendance: AttendanceStore(db),
      config: const TillConfig(),
    );
  }

  Future<void> shoot(WidgetTester t, String name) async {
    await settle(t);
    late final List<int> png;
    await t.runAsync(() async {
      final boundary =
          shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1.0);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      png = data!.buffer.asUint8List();
    });
    File('${dir.path}/$name.png').writeAsBytesSync(png);
    // ignore: avoid_print
    print('WROTE ${dir.path}/$name.png ${png.length} bytes');
  }

  Future<void> signIn(WidgetTester t) async {
    await t.tap(find.byKey(const Key('user-sara')));
    await settle(t);
    for (final d in '1234'.split('')) {
      await t.tap(find.byKey(Key('key-$d')));
      await t.pump();
    }
    await t.tap(find.byKey(const Key('pin-ok')));
    await settle(t, frames: 80);
  }

  Future<void> openDrawer(WidgetTester t) async {
    await t.tap(find.byTooltip('Open navigation menu').first);
    await settle(t);
  }

  Future<void> back(WidgetTester t) async {
    await t.pageBack();
    await settle(t);
  }

  testWidgets('the tour, in the light theme', (t) async {
    await t.pumpWidget(RepaintBoundary(key: shotKey, child: app()));
    await shoot(t, '01-login');

    await signIn(t);
    await shoot(t, '02-floor');

    // Seat table 2 and ring a realistic order.
    await t.tap(find.byKey(Key('table-tile-${floor[1].id}')));
    await settle(t);
    await t.tap(find.byKey(const Key('product-11')));
    await settle(t, frames: 10);
    await t.tap(find.byKey(const Key('product-21')));
    await settle(t, frames: 10);
    await t.tap(find.byKey(const Key('product-21')));
    await settle(t, frames: 10);
    await t.tap(find.byKey(const Key('product-30')));
    await shoot(t, '03-sell-counter');

    // An item that asks questions: the modifier sheet.
    await t.tap(find.byKey(const Key('product-10')));
    await settle(t);
    await shoot(t, '04-modifier-sheet');
    await t.tap(find.byKey(const Key('mod-102')));
    await t.pump();
    await t.tap(find.byKey(const Key('mod-201')));
    await t.pump();
    await t.tap(find.byKey(const Key('confirm-modifiers')));
    await settle(t);
    await shoot(t, '05-sell-with-modifiers');

    // The payment sheet, with cash chosen so the received / quick-note row shows.
    await t.tap(find.byKey(const Key('pay')));
    await settle(t);
    await t.tap(find.byKey(const Key('method-1')));
    await settle(t);
    await shoot(t, '06-payment');
    await t.tap(find.text('Cancel').last);
    await settle(t);

    // Park the tab: the floor now reads table 2 as occupied.
    await t.tap(find.byKey(const Key('hold')));
    await settle(t, frames: 60);
    await shoot(t, '07-floor-occupied');

    await openDrawer(t);
    await shoot(t, '08-drawer');

    await t.tap(find.byKey(const Key('nav-open-orders')));
    await settle(t, frames: 60);
    await shoot(t, '09-open-orders');
    await back(t);

    await openDrawer(t);
    await t.tap(find.byKey(const Key('nav-shift')));
    await settle(t, frames: 60);
    await shoot(t, '10-shift');
    await back(t);

    await openDrawer(t);
    await t.tap(find.byKey(const Key('nav-report')));
    await settle(t, frames: 60);
    await shoot(t, '11-reports');
    await back(t);

    await openDrawer(t);
    // The drawer grew a profile header, so its tail lives below the fold on a
    // short window and has to be scrolled into being before it can be tapped.
    await t.scrollUntilVisible(
      find.byKey(const Key('nav-settings')),
      200,
      scrollable: find
          .descendant(of: find.byType(Drawer), matching: find.byType(Scrollable))
          .first,
    );
    await settle(t, frames: 10);
    await t.tap(find.byKey(const Key('nav-settings')));
    await settle(t, frames: 60);
    await shoot(t, '12-settings');
    await back(t);

    // Last stop, so nothing has to navigate back out of it.
    await openDrawer(t);
    await t.tap(find.byKey(const Key('nav-kitchen')));
    await settle(t, frames: 60);
    await shoot(t, '13-kitchen');
  });

  testWidgets('the tour, with the lights off', (t) async {
    SettingsStore(db).themeMode = 'dark';

    await t.pumpWidget(RepaintBoundary(key: shotKey, child: app()));
    await shoot(t, '14-login-dark');

    await signIn(t);
    await shoot(t, '15-floor-dark');

    await t.tap(find.byKey(Key('table-tile-${floor[2].id}')));
    await settle(t);
    await t.tap(find.byKey(const Key('product-12')));
    await settle(t, frames: 10);
    await t.tap(find.byKey(const Key('product-31')));
    await settle(t, frames: 10);
    await t.tap(find.byKey(const Key('product-40')));
    await shoot(t, '16-sell-dark');

    await t.tap(find.byKey(const Key('pay')));
    await settle(t);
    await t.tap(find.byKey(const Key('method-2')));
    await settle(t);
    await shoot(t, '17-payment-dark');
  });

  testWidgets('the floor editor', (t) async {
    await t.pumpWidget(RepaintBoundary(key: shotKey, child: app()));
    await signIn(t);
    await t.tap(find.byKey(const Key('toggle-edit')));
    await settle(t);
    await shoot(t, '20-floor-editor');

    // Drag one table a cell over: the drop selects it and the fine controls
    // appear on the bar.
    final gesture = await t
        .startGesture(t.getCenter(find.byKey(Key('table-edit-${floor[1].id}'))));
    await t.pump(const Duration(milliseconds: 400));
    await gesture.moveBy(const Offset(140, 140));
    await t.pump();
    await gesture.up();
    await settle(t);
    await shoot(t, '21-floor-editor-selected');
  });

  // The shop runs the till in Arabic too, so the two busiest screens are
  // photographed under RTL.
  testWidgets('the tour, in Arabic', (t) async {
    SettingsStore(db).language = 'ar';

    await t.pumpWidget(RepaintBoundary(key: shotKey, child: app()));
    await signIn(t);
    await shoot(t, '18-floor-ar');

    await t.tap(find.byKey(Key('table-tile-${floor[0].id}')));
    await settle(t);
    await t.tap(find.byKey(const Key('product-11')));
    await settle(t, frames: 10);
    await t.tap(find.byKey(const Key('product-30')));
    await shoot(t, '19-sell-ar');
  });
}
