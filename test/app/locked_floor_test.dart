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
import 'package:offline_pos/features/auth/login_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async =>
      const [];
}

/// The till opens on its floor, locked: Begin (or a table tap) asks who is
/// signing in, and signing in unlocks the same floor.
void main() {
  late Db db;
  late AuditLog audit;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    ShiftStore(db).openShift(openingFloat: 100, cashierId: 'mo');
    final settings = SettingsStore(db);
    settings.askCashierOnOpen = false;
    settings.lanRolePromptDismissed = true;
    audit = AuditLog(db);
    TableStore(db).add(name: '5');
    final auth =
        AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit);
    await auth.enrol(id: 'mo', name: 'Mo', pin: '9999', role: 'manager');
    WizardStore(db).dismiss(WizardId.firstSale, 'mo');
  });
  tearDown(() => db.close());

  Widget app() {
    final outbox = Outbox(store: SqliteOutboxStore(db), senders: {});
    return PosApp(
      auth: AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit),
      users: UserStore(db),
      catalogue: CatalogueStore(db),
      orders: OrderStore(db, ownDeviceId: 'till-1'),
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
      settings: SettingsStore(db),
      customers: CustomerStore(db),
      attendance: AttendanceStore(db),
      lockedFloorHome: true,
      config: const TillConfig(),
    );
  }

  Future<void> signInMo(WidgetTester t) async {
    await t.tap(find.byKey(const Key('user-mo')));
    await t.pumpAndSettle();
    for (final d in '9999'.split('')) {
      await t.tap(find.byKey(Key('key-$d')));
      await t.pump();
    }
    await t.tap(find.byKey(const Key('pin-ok')));
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 50));
      if (find.byKey(const Key('locked-floor')).evaluate().isEmpty) break;
    }
    await t.pumpAndSettle();
  }

  testWidgets('opens on the locked floor, not the sign-in screen', (t) async {
    await t.pumpWidget(app());
    await t.pumpAndSettle();
    expect(find.byKey(const Key('locked-floor')), findsOneWidget);
    expect(find.byKey(const Key('floor-locked')), findsOneWidget);
    expect(find.byType(LoginScreen), findsNothing);
    // No tools while locked: nothing to edit, no order buttons.
    expect(find.byKey(const Key('toggle-edit')), findsNothing);
    expect(find.byKey(const Key('floor-takeaway')), findsNothing);
  });

  testWidgets('Begin opens sign-in, and signing in unlocks the floor', (t) async {
    await t.pumpWidget(app());
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('floor-action-begin')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('login-over-floor')), findsOneWidget);

    await signInMo(t);
    expect(find.byKey(const Key('login-over-floor')), findsNothing);
    expect(find.byKey(const Key('locked-floor')), findsNothing);
    expect(find.byKey(const Key('floor-locked')), findsNothing);
    expect(find.byKey(const Key('toggle-edit')), findsOneWidget);
  });

  testWidgets('a table tap while locked asks who is signing in', (t) async {
    await t.pumpWidget(app());
    await t.pumpAndSettle();
    await t.tap(find.text('5').first);
    await t.pumpAndSettle();
    expect(find.byKey(const Key('login-over-floor')), findsOneWidget);
    // Backing out leaves the floor locked.
    await t.tap(find.byKey(const Key('login-close')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('login-over-floor')), findsNothing);
    expect(find.byKey(const Key('floor-locked')), findsOneWidget);
  });

  testWidgets('switching room while locked asks who is signing in too',
      (t) async {
    TableStore(db).add(name: '9', section: 'Terrace');
    await t.pumpWidget(app());
    await t.pumpAndSettle();
    await t.tap(find.text('Terrace').first);
    await t.pumpAndSettle();
    expect(find.byKey(const Key('login-over-floor')), findsOneWidget);
  });

  testWidgets('a button switched off in settings is left off the bar',
      (t) async {
    SettingsStore(db).floorActionsHidden = {'quit'};
    await t.pumpWidget(app());
    await t.pumpAndSettle();
    expect(find.byKey(const Key('floor-action-begin')), findsOneWidget);
    expect(find.byKey(const Key('floor-action-quit')), findsNothing);
  });

  testWidgets('End locks the floor again', (t) async {
    await t.pumpWidget(app());
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('floor-action-begin')));
    await t.pumpAndSettle();
    await signInMo(t);
    expect(find.byKey(const Key('floor-locked')), findsNothing);

    await t.tap(find.byKey(const Key('floor-action-end')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('locked-floor')), findsOneWidget);
    expect(find.byKey(const Key('floor-locked')), findsOneWidget);
  });
}
