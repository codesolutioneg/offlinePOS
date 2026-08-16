import 'dart:io';

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
import 'package:offline_pos/core/export/db_backup.dart';
import 'package:offline_pos/core/onboarding/wizard_store.dart';
import 'package:offline_pos/core/printing/printer_discovery.dart';
import 'package:offline_pos/core/printing/printer_registry.dart';
import 'package:offline_pos/core/sync/odoo_endpoint.dart';
import 'package:offline_pos/core/sync/odoo_wiring.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/core/sync/server_probe.dart';
import 'package:offline_pos/core/sync/sync_service.dart';
import 'package:offline_pos/features/support/diagnostics_screen.dart';
import 'package:offline_pos/features/settings/server_settings_screen.dart';
import 'package:offline_pos/features/tables/table_floor_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// The two support actions a shop reaches through the app rather than through a
/// screen a test can build on its own: asking the server whether it is there, and
/// taking a copy of the till. Both are dead unless the shell hands them down.
void main() {
  late Directory dir;
  late Db db;
  late SqliteOutboxStore outboxStore;
  late AuditLog audit;

  final asked = <OdooEndpoint>[];
  late ServerCheckResult answer;

  setUpAll(useSystemSqlite);
  setUp(() async {
    // A real file on disk, because the backup is only meaningful for a till that
    // has one.
    dir = Directory.systemTemp.createTempSync('pos-ops-wiring');
    db = Db.open('${dir.path}${Platform.pathSeparator}pos.db');
    outboxStore = SqliteOutboxStore(db);
    audit = AuditLog(db);
    asked.clear();
    answer = const ServerCheckResult(ServerCheck.ok);
  });
  tearDown(() {
    db.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<AuthService> managerOnTheTill() async {
    final auth = AuthService(
        users: UserStore(db), hasher: FakePinHasher(), audit: AuditLog(db));
    await auth.enrol(id: 'sara', name: 'Sara', pin: '1234', role: 'manager');
    return auth;
  }

  Widget app(AuthService auth) {
    final outbox = Outbox(store: outboxStore, senders: {});
    return PosApp(
      auth: auth,
      users: UserStore(db),
      catalogue: CatalogueStore(db),
      orders: OrderStore(db, ownDeviceId: 'till-1'),
      outbox: outbox,
      audit: audit,
      sync: SyncService(
        outbox: outbox,
        catalogue: CatalogueStore(db),
        outboxStore: outboxStore,
        deviceId: 'till-1',
        appVersion: 'test',
      ),
      outboxStore: outboxStore,
      printers: PrinterRegistry(discovery: _NoPrinters()),
      wizards: WizardStore(db),
      shifts: ShiftStore(db),
      deviceId: 'till-1',
      endpoints: OdooEndpointStore(db),
      odoo: OdooWiring(outbox: outbox),
      tables: TableStore(db),
      settings: SettingsStore(db),
      customers: CustomerStore(db),
      attendance: AttendanceStore(db),
      // Exactly what main.dart hands down, with the network and the platform
      // directories stood in for.
      checkServer: (e) async {
        asked.add(e);
        return answer;
      },
      backup: () => backupDatabase(db, destination: () async => dir),
    );
  }

  Future<void> boot(WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1280, 1600));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(app(await managerOnTheTill()));
    await t.tap(find.byKey(const Key('user-sara')));
    await t.pump();
    for (final d in '1234'.split('')) {
      await t.tap(find.byKey(Key('key-$d')));
      await t.pump();
    }
    await t.tap(find.byKey(const Key('pin-ok')));
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 50));
      if (find.byKey(const Key('pin-ok')).evaluate().isEmpty) break;
    }
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('wizard-skip')));
    await t.pumpAndSettle();
    // Signing in lands on the floor home, which carries the same drawer the
    // counter does, so support and the server screen are reached from here
    // without opening an order first.
    expect(find.byType(TableFloorScreen), findsOneWidget);
  }

  Future<void> openDrawerItem(WidgetTester t, String key) async {
    await t.tap(find.byType(DrawerButton));
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key(key)));
    await t.pumpAndSettle();
  }

  testWidgets('Test connection on the server screen asks the real probe',
      (t) async {
    answer = const ServerCheckResult(ServerCheck.badCredentials,
        detail: 'Access denied');
    await boot(t);
    await openDrawerItem(t, 'nav-settings');
    await t.tap(find.byKey(const Key('set-server')));
    await t.pumpAndSettle();
    expect(find.byType(ServerSettingsScreen), findsOneWidget);

    await t.enterText(find.byKey(const Key('field-url')), 'https://shop.example.com');
    await t.enterText(find.byKey(const Key('field-db')), 'shop');
    await t.enterText(find.byKey(const Key('field-login')), 'till@example.com');
    await t.tap(find.byKey(const Key('test-connection')));
    await t.pumpAndSettle();

    expect(asked, hasLength(1),
        reason: 'the shell must hand the screen a probe, or the button does nothing');
    expect(asked.single.baseUrl, 'https://shop.example.com');
    expect(
        t.widget<Text>(find.byKey(const Key('settings-message'))).data,
        contains('Access denied'));
  });

  testWidgets('Back up now writes a real copy of this till', (t) async {
    await boot(t);
    await openDrawerItem(t, 'nav-support');
    expect(find.byType(DiagnosticsScreen), findsOneWidget);

    await t.tap(find.byKey(const Key('backup-db')));
    // Copying the file is real IO, which does not run on the test's fake clock.
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pumpAndSettle();

    final path =
        t.widget<SelectableText>(find.byKey(const Key('backup-result'))).data!;
    expect(File(path).existsSync(), isTrue,
        reason: 'the shell must hand Diagnostics a backup, or the button is a label');
    // The till it was taken from is still the one being used.
    expect(db.raw.select('SELECT count(*) c FROM users').first['c'], greaterThan(0));
  });
}
