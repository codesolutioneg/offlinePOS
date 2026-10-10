// Test-only. The tour harness, pointed at the screens the shop network, the SQL
// console and the session close changed: the role question, the console's
// answers, a close with no branch set, and the new screens in Arabic. Run it
// through tool/run_shots.sh like the tour.
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
import '../test/ui/pay_button.dart';

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

  final dir = Directory(Platform.environment['SHOT_DIR'] ?? '/tmp/shots-parity');

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
    // The tooltip is translated, so open it from the scaffold instead.
    t.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
    await settle(t);
  }

  /// Pops the top route; some of these screens draw their own back arrow.
  Future<void> back(WidgetTester t) async {
    await Navigator.of(t.element(find.byType(Scaffold).last)).maybePop();
    await settle(t);
  }

  Future<void> openFromDrawer(WidgetTester t, String key) async {
    await openDrawer(t);
    await t.scrollUntilVisible(
      find.byKey(Key(key)),
      200,
      scrollable: find
          .descendant(of: find.byType(Drawer), matching: find.byType(Scrollable))
          .first,
    );
    await settle(t, frames: 10);
    await t.tap(find.byKey(Key(key)));
    await settle(t, frames: 60);
  }

  Future<void> openSql(WidgetTester t) async {
    await openFromDrawer(t, 'nav-support');
    await t.scrollUntilVisible(find.byKey(const Key('open-sql')), 200,
        scrollable: find.byType(Scrollable).last);
    await settle(t, frames: 10);
    await t.tap(find.byKey(const Key('open-sql')));
    await settle(t, frames: 60);
  }

  /// enterText does not always land on the desktop build, so set the field
  /// directly.
  void typeSql(WidgetTester t, String sql) =>
      t.widget<TextField>(find.byKey(const Key('sql-input'))).controller!.text =
          sql;

  Future<void> runSql(WidgetTester t, String sql, {bool confirm = false}) async {
    typeSql(t, sql);
    await t.tap(find.byKey(const Key('sql-run')));
    await settle(t);
    if (confirm) {
      expect(find.byKey(const Key('sql-write-confirm')), findsOneWidget);
      await t.tap(find.byKey(const Key('sql-write-ok')));
      await settle(t);
    }
  }

  testWidgets('a manager is asked about the shop network, then the SQL console',
      (t) async {
    await t.pumpWidget(RepaintBoundary(key: shotKey, child: app()));
    await signIn(t);
    expect(find.byKey(const Key('lan-role-prompt')), findsOneWidget);
    await shoot(t, '30-lan-role-prompt');
    await t.tap(find.byKey(const Key('lan-role-prompt-skip')));
    await settle(t);
    expect(find.byKey(const Key('lan-role-prompt')), findsNothing);

    await openSql(t);
    await runSql(t, 'SELECT id, name, role FROM users ORDER BY id');
    expect(find.byKey(const Key('sql-row-count')), findsOneWidget);
    await shoot(t, '31-sql-rows');

    typeSql(t, "WITH x AS (SELECT 1) DELETE FROM users WHERE id = 'omar'");
    await t.tap(find.byKey(const Key('sql-run')));
    await settle(t);
    expect(find.byKey(const Key('sql-write-confirm')), findsOneWidget);
    await shoot(t, '32-sql-write-confirm');
    await t.tap(find.text('Cancel').last);
    await settle(t);

    await runSql(t, 'DELETE FROM audit_log', confirm: true);
    expect(find.text('That statement is not allowed here.'), findsOneWidget);
    await shoot(t, '33-sql-audit-blocked');
  });

  testWidgets('a till with no branch still closes its shift', (t) async {
    SettingsStore(db).lanRolePromptDismissed = true;
    await t.pumpWidget(RepaintBoundary(key: shotKey, child: app()));
    await signIn(t);

    await t.tap(find.byKey(Key('table-tile-${floor[1].id}')));
    await settle(t, frames: 120);
    await t.tap(find.byKey(const Key('product-21')));
    await settle(t, frames: 10);
    await t.tap(findPay());
    await settle(t);
    await t.tap(find.byKey(const Key('method-2')));
    await settle(t);
    await t.tap(find.byKey(const Key('confirm-payment')));
    await settle(t, frames: 80);

    await openFromDrawer(t, 'nav-shift');
    await t.ensureVisible(find.byKey(const Key('close-shift')));
    await settle(t, frames: 10);
    await shoot(t, '34-shift-before-close');
    await t.tap(find.byKey(const Key('close-shift')));
    await settle(t);
    for (final d in '500'.split('')) {
      await t.tap(find.byKey(Key('key-$d')));
      await t.pump();
    }
    await t.tap(find.byKey(const Key('keypad-ok')));
    await settle(t);
    expect(find.byKey(const Key('cash-variance-block')), findsNothing);
    await t.tap(find.byKey(const Key('confirm-close-shift')));
    for (var i = 0; i < 60; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await t.pump(const Duration(milliseconds: 100));
      if (find.byKey(const Key('session-done')).evaluate().isNotEmpty) break;
    }
    expect(find.byKey(const Key('session-done')), findsOneWidget);
    expect(find.textContaining('pick the branch under Server settings'),
        findsOneWidget);
    expect(ShiftStore(db).currentOpenShift(), isNull);
    await shoot(t, '35-session-closed-no-branch');
  });

  testWidgets('the new screens, in Arabic', (t) async {
    SettingsStore(db)
      ..language = 'ar'
      ..lanRolePromptDismissed = true;
    await t.pumpWidget(RepaintBoundary(key: shotKey, child: app()));
    await signIn(t);

    await openFromDrawer(t, 'nav-settings');
    await t.scrollUntilVisible(find.byKey(const Key('set-lan')), 200,
        scrollable: find.byType(Scrollable).last);
    await settle(t, frames: 10);
    await t.tap(find.byKey(const Key('set-lan')));
    await settle(t, frames: 60);
    await shoot(t, '36-lan-settings-ar');
    await back(t);
    await back(t);

    await openFromDrawer(t, 'nav-shift');
    await shoot(t, '37-shift-ar');
    await back(t);

    await openFromDrawer(t, 'nav-support');
    await shoot(t, '38-support-ar');
  });
}
