import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/app/pos_app.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/auth/auth_service.dart';
import 'package:offline_pos/core/auth/permissions.dart';
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

/// A role the shop invented, from the manager creating it to a new starter being
/// put on it.
///
/// The store has always taken any role string. What is covered here is the part
/// that was missing: a manager can only reach the two built-in roles unless the
/// screens offer more, and a rename that leaves the roster behind hands somebody a
/// role with no permissions.
void main() {
  late Db db;
  late OrderStore orders;
  late SettingsStore settings;
  late UserStore users;
  late AuditLog audit;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    orders = OrderStore(db);
    settings = SettingsStore(db);
    users = UserStore(db);
    audit = AuditLog(db);
    await AuthService(users: users, hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'sara', name: 'Sara', pin: '1234', role: 'manager');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');
  });
  tearDown(() => db.close());

  Widget app() {
    final outbox = Outbox(store: SqliteOutboxStore(db), senders: {});
    return PosApp(
      auth: AuthService(users: users, hasher: FakePinHasher(), audit: audit),
      users: users,
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

  void draftOnTheTill() {
    final order = Order(deviceId: 'till-1', cashierId: 'sara')
      ..lines.add(OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 10));
    orders.save(order, announce: false);
  }

  void tallWindow(WidgetTester t) {
    t.view.physicalSize = const Size(1000, 3200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

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

  Future<void> openSettingsHub(WidgetTester t) async {
    t.state<ScaffoldState>(find
            .descendant(of: find.byType(SellScreen), matching: find.byType(Scaffold))
            .first)
        .openDrawer();
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-settings')));
    await t.pumpAndSettle();
  }

  Future<void> openRoles(WidgetTester t) async {
    await openSettingsHub(t);
    await t.tap(find.byKey(const Key('set-roles')));
    await t.pumpAndSettle();
  }

  Future<void> typeRoleName(WidgetTester t, String name) async {
    await t.enterText(find.byKey(const Key('role-name-field')), name);
    await t.tap(find.byKey(const Key('role-name-save')));
    await t.pumpAndSettle();
  }

  testWidgets('a manager can invent a role and grant it what it needs', (t) async {
    tallWindow(t);
    draftOnTheTill();
    await t.pumpWidget(app());
    await signIn(t);
    await openRoles(t);

    await t.tap(find.byKey(const Key('add-role')));
    await t.pumpAndSettle();
    await typeRoleName(t, 'Supervisor');

    // The new role gets its own block of switches, separate from the cashier's.
    await t.tap(find.byKey(const Key('perm-Supervisor-void_line')));
    await t.pumpAndSettle();

    expect(settings.customRoles, ['Supervisor']);
    expect(settings.roleCan('Supervisor', Permission.voidLine), isTrue);
    expect(settings.roleCan('cashier', Permission.voidLine), isFalse,
        reason: 'the cashier switches must not have moved');
  });

  testWidgets('the roster offers the invented role to a new starter', (t) async {
    tallWindow(t);
    draftOnTheTill();
    settings.addCustomRole('Supervisor');

    await t.pumpWidget(app());
    await signIn(t);
    await openSettingsHub(t);
    await t.tap(find.byKey(const Key('set-staff')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('add-staff')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('staff-role')));
    await t.pumpAndSettle();

    expect(find.text('Supervisor'), findsWidgets,
        reason: 'the shell must hand the roster the roles the shop configured');

    await t.tap(find.byKey(const Key('role-option-Supervisor')).last);
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('staff-name')), 'Omar');
    await t.enterText(find.byKey(const Key('staff-pin')), '4321');
    await t.tap(find.byKey(const Key('staff-form-save')));
    await t.pumpAndSettle();

    expect(users.all().firstWhere((c) => c.name == 'Omar').role, 'Supervisor');
  });

  testWidgets('renaming a role takes the staff standing on it along', (t) async {
    tallWindow(t);
    draftOnTheTill();
    settings.addCustomRole('Supervisor');
    settings.setRolePermission('Supervisor', Permission.refund, true);
    await AuthService(users: users, hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'omar', name: 'Omar', pin: '4321', role: 'Supervisor');

    await t.pumpWidget(app());
    await signIn(t);
    await openRoles(t);
    await t.tap(find.byKey(const Key('role-menu-Supervisor')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('rename-Supervisor')));
    await t.pumpAndSettle();
    await typeRoleName(t, 'Shift lead');

    expect(settings.customRoles, ['Shift lead']);
    expect(users.all().firstWhere((c) => c.id == 'omar').role, 'Shift lead',
        reason: 'an account left on the old name would have no permissions');
    expect(settings.roleCan('Shift lead', Permission.refund), isTrue);
  });

  testWidgets('deleting a role hands its staff back to cashier', (t) async {
    tallWindow(t);
    draftOnTheTill();
    settings.addCustomRole('Supervisor');
    await AuthService(users: users, hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'omar', name: 'Omar', pin: '4321', role: 'Supervisor');

    await t.pumpWidget(app());
    await signIn(t);
    await openRoles(t);
    await t.tap(find.byKey(const Key('role-menu-Supervisor')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('delete-Supervisor')));
    await t.pumpAndSettle();
    // The count of who it affects is shown before it happens.
    expect(find.textContaining('1'), findsWidgets);
    await t.tap(find.byKey(const Key('delete-role-confirm')));
    await t.pumpAndSettle();

    expect(settings.customRoles, isEmpty);
    expect(users.all().firstWhere((c) => c.id == 'omar').role, 'cashier');
  });
}
