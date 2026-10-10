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
import 'package:offline_pos/core/sync/odoo_endpoint.dart';
import 'package:offline_pos/core/sync/odoo_wiring.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/core/sync/sync_service.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/domain/table_section_config.dart';
import 'package:offline_pos/features/support/sql_console_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// The doors a cashier must not walk through alone, driven from the sign-in
/// screen the way staff reach them.
void main() {
  late Db db;
  late SettingsStore settings;
  late AuditLog audit;

  setUpAll(useSystemSqlite);

  setUp(() async {
    db = Db.open(':memory:');
    ShiftStore(db).openShift(openingFloat: 100, cashierId: 'sara');
    settings = SettingsStore(db);
    audit = AuditLog(db);
    CatalogueStore(db).replaceAll(
      categories: const [Category(id: 1, name: 'Food')],
      products: const [Product(id: 10, name: 'Pizza', price: 30, categoryId: 1)],
      groups: const [],
      productGroupIds: const {},
      paymentMethods: const [PaymentMethod(id: 1, name: 'Cash', isCash: true)],
      refreshedAt: DateTime.now().toUtc(),
    );
    final auth =
        AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit);
    await auth.enrol(id: 'sara', name: 'Sara', pin: '1234', role: 'manager');
    await auth.enrol(id: 'omar', name: 'Omar', pin: '5678');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');
    WizardStore(db).dismiss(WizardId.firstSale, 'omar');
    settings.askGuestCount = false;
  });
  tearDown(() => db.close());

  Widget app() {
    final outboxStore = SqliteOutboxStore(db);
    final outbox = Outbox(store: outboxStore, senders: {});
    return PosApp(
      auth: AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit),
      users: UserStore(db),
      catalogue: CatalogueStore(db),
      orders: OrderStore(db),
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
      settings: settings,
      customers: CustomerStore(db),
      attendance: AttendanceStore(db),
      config: const TillConfig(),
    );
  }

  Future<void> signIn(WidgetTester t, String id, String pin) async {
    await t.binding.setSurfaceSize(const Size(1280, 1600));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(app());
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('user-$id')));
    await t.pumpAndSettle();
    for (final d in pin.split('')) {
      await t.tap(find.byKey(Key('key-$d')));
      await t.pump();
    }
    await t.tap(find.byKey(const Key('pin-ok')));
    await t.pumpAndSettle();
  }

  Future<void> openSqlFromSupport(WidgetTester t) async {
    await t.tap(find.byTooltip('Open navigation menu'));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.byKey(const Key('nav-support')), 200,
        scrollable: find
            .descendant(of: find.byType(Drawer), matching: find.byType(Scrollable))
            .first);
    await t.tap(find.byKey(const Key('nav-support')));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.byKey(const Key('open-sql')), 200,
        scrollable: find.byType(Scrollable).last);
    await t.tap(find.byKey(const Key('open-sql')));
    await t.pumpAndSettle();
  }

  Future<void> runSql(WidgetTester t, String sql) async {
    await t.enterText(find.byKey(const Key('sql-input')), sql);
    await t.tap(find.byKey(const Key('sql-run')));
    await t.pumpAndSettle();
  }

  List<String> actions() => [
        for (final r in db.raw.select('SELECT event FROM audit_log ORDER BY rowid'))
          r['event'] as String
      ];

  group('shop network role prompt', () {
    testWidgets('a manager is asked once, and Skip is remembered', (t) async {
      await signIn(t, 'sara', '1234');
      expect(find.byKey(const Key('lan-role-prompt')), findsOneWidget);
      await t.tap(find.byKey(const Key('lan-role-prompt-skip')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('lan-role-prompt')), findsNothing);
      expect(settings.lanRolePromptDismissed, isTrue);
      expect(settings.deviceRole, DeviceRole.unset);
    });

    testWidgets('a cashier is not asked, and the question waits for a manager',
        (t) async {
      await signIn(t, 'omar', '5678');
      expect(find.byKey(const Key('lan-role-prompt')), findsNothing);
      expect(settings.lanRolePromptDismissed, isFalse);
      expect(settings.deviceRole, DeviceRole.unset);
    });
  });

  group('SQL console from Support', () {
    setUp(() => settings.lanRolePromptDismissed = true);

    testWidgets('a cashier gets the manager approval, and Cancel keeps it shut',
        (t) async {
      await signIn(t, 'omar', '5678');
      await openSqlFromSupport(t);
      expect(find.text('Manager approval'), findsOneWidget);
      await t.tap(find.text('Cancel').last);
      await t.pumpAndSettle();
      expect(find.byType(SqlConsoleScreen), findsNothing);
      expect(actions(), contains('permission.denied'));
    });

    testWidgets('a wrong manager PIN keeps it shut', (t) async {
      await signIn(t, 'omar', '5678');
      await openSqlFromSupport(t);
      for (final d in '5678'.split('')) {
        await t.tap(find.descendant(
            of: find.byType(AlertDialog), matching: find.byKey(Key('key-$d'))));
        await t.pump();
      }
      await t.tap(find.byKey(const Key('manager-ok')));
      await t.pumpAndSettle();
      expect(find.byType(SqlConsoleScreen), findsNothing);
    });

    testWidgets('a manager PIN on the spot opens it for the cashier', (t) async {
      await signIn(t, 'omar', '5678');
      await openSqlFromSupport(t);
      for (final d in '1234'.split('')) {
        await t.tap(find.descendant(
            of: find.byType(AlertDialog), matching: find.byKey(Key('key-$d'))));
        await t.pump();
      }
      await t.tap(find.byKey(const Key('manager-ok')));
      await t.pumpAndSettle();
      expect(find.byType(SqlConsoleScreen), findsOneWidget);
    });

    testWidgets('a manager goes straight in; writes ask first, the key and audit are shut',
        (t) async {
      await signIn(t, 'sara', '1234');
      await openSqlFromSupport(t);
      expect(find.text('Manager approval'), findsNothing);
      expect(find.byType(SqlConsoleScreen), findsOneWidget);

      await runSql(t, 'SELECT id FROM users ORDER BY id');
      expect(find.byKey(const Key('sql-row-count')), findsOneWidget);

      // A delete dressed as a read still asks, and Cancel leaves the rows.
      await runSql(t,
          "WITH x AS (SELECT 1) DELETE FROM users WHERE id = 'omar'");
      expect(find.byKey(const Key('sql-write-confirm')), findsOneWidget);
      await t.tap(find.text('Cancel').last);
      await t.pumpAndSettle();
      expect(db.raw.select("SELECT 1 FROM users WHERE id = 'omar'"), hasLength(1));

      await runSql(t, "PRAGMA main.key = 'x'");
      if (find.byKey(const Key('sql-write-confirm')).evaluate().isNotEmpty) {
        await t.tap(find.byKey(const Key('sql-write-ok')));
        await t.pumpAndSettle();
      }
      expect(find.text('That statement is not allowed here.'), findsOneWidget);

      await runSql(t, 'DELETE FROM audit_log');
      await t.tap(find.byKey(const Key('sql-write-ok')));
      await t.pumpAndSettle();
      expect(find.text('That statement is not allowed here.'), findsOneWidget);
      expect(actions(), contains('sql.blocked'));

      await runSql(t, 'SELECT 1; DELETE FROM users');
      expect(find.byKey(const Key('sql-error')), findsOneWidget);
      expect(db.raw.select('SELECT 1 FROM users'), hasLength(2));
    });
  });
}
