// Test-only. Drives the real app on the Linux embedder and writes a PNG per
// screen into SHOT_DIR, so a change to the till can be looked at rather than
// only asserted. Run it through tool/run_shots.sh, which supplies the display,
// the dbus session and the unlocked keyring the app expects.
//
// This is not a golden test: nothing here fails on a pixel difference. It exists
// so a human can see what the screen actually looks like, which the widget tests
// cannot show because they draw every glyph as a box.
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
/// captured directly. Dialogs and dropdown menus live in the app's own overlay,
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
  late PosTable table6;
  late AuditLog audit;

  final dir =
      Directory(Platform.environment['SHOT_DIR'] ?? '/tmp/shots-guest-count');

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
    ShiftStore(db).openShift(openingFloat: 100, cashierId: 'sara');
    audit = AuditLog(db);
    tables = TableStore(db);
    // Six seats, which is the case the owner photographed: the prompt has to
    // offer every one of them.
    table6 = tables.add(name: '4', seats: 6);
    CatalogueStore(db).replaceAll(
      categories: const [Category(id: 1, name: 'Pizza')],
      products: const [
        Product(id: 10, name: 'Margherita', price: 250, categoryId: 1),
      ],
      groups: const [],
      productGroupIds: const {},
      refreshedAt: DateTime.now().toUtc(),
    );
    await AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'sara', name: 'Sara', pin: '1234');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');
    SettingsStore(db).askGuestCount = true;
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

  testWidgets('the covers prompt, as a list', (t) async {
    await t.pumpWidget(RepaintBoundary(key: shotKey, child: app()));
    await shoot(t, '01-login');

    await signIn(t);
    await shoot(t, '02-floor');

    await t.tap(find.byKey(Key('table-tile-${table6.id}')));
    await shoot(t, '03-guest-count-closed');

    await t.tap(find.byKey(const Key('guest-count-dropdown')));
    await shoot(t, '04-guest-count-open');

    await t.tap(find
        .descendant(
            of: find.byKey(const Key('guests-5')), matching: find.text('5'))
        .last);
    await shoot(t, '05-sell-with-covers');
  });

  // The shop runs the till in Arabic, so the list is photographed there too: a
  // dropdown that reads correctly left to right can still open wrong under RTL.
  testWidgets('the covers prompt in Arabic', (t) async {
    SettingsStore(db).language = 'ar';

    await t.pumpWidget(RepaintBoundary(key: shotKey, child: app()));
    await signIn(t);

    await t.tap(find.byKey(Key('table-tile-${table6.id}')));
    await shoot(t, '06-guest-count-closed-ar');

    await t.tap(find.byKey(const Key('guest-count-dropdown')));
    await shoot(t, '07-guest-count-open-ar');
  });
}
