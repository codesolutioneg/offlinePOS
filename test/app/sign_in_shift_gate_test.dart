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
import 'package:offline_pos/features/tables/table_floor_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;
  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async =>
      const [];
}

/// Who may unlock the till, and what unlocking does.
///
/// Opening the shift is the manager's: until one is open only a manager signs
/// in, so a cashier cannot open a drawer or ring a table on their own. Once it
/// is open anyone on the roster signs in with their PIN, and signing in is also
/// clocking in.
void main() {
  late Db db;
  late AttendanceStore attendance;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    SettingsStore(db)
      ..askGuestCount = false
      ..askCashierOnOpen = false
      ..lanRolePromptDismissed = true;
    attendance = AttendanceStore(db);
    final auth = AuthService(
        users: UserStore(db), hasher: FakePinHasher(), audit: AuditLog(db));
    await auth.enrol(id: 'ana', name: 'Ana', pin: '4321');
    await auth.enrol(id: 'mo', name: 'Mo', pin: '9999', role: 'manager');
    for (final id in ['ana', 'mo']) {
      WizardStore(db).dismiss(WizardId.firstSale, id);
    }
  });
  tearDown(() => db.close());

  Widget app() {
    final outbox = Outbox(store: SqliteOutboxStore(db), senders: {});
    final audit = AuditLog(db);
    return PosApp(
      auth: AuthService(
          users: UserStore(db), hasher: FakePinHasher(), audit: audit),
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
      attendance: attendance,
      config: const TillConfig(),
    );
  }

  Future<void> signIn(WidgetTester t, String id, String pin) async {
    await t.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(app());
    await t.tap(find.byKey(Key('user-$id')));
    await t.pumpAndSettle();
    if (find.byKey(const Key('pin-ok')).evaluate().isEmpty) return;
    for (final d in pin.split('')) {
      await t.tap(find.byKey(Key('key-$d')));
      await t.pump();
    }
    await t.tap(find.byKey(const Key('pin-ok')));
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 50));
      if (find.byKey(const Key('pin-ok')).evaluate().isEmpty) break;
    }
    await t.pumpAndSettle();
  }

  testWidgets('with no shift open a cashier is turned away before the PIN',
      (t) async {
    await signIn(t, 'ana', '4321');

    expect(find.byType(TableFloorScreen), findsNothing);
    expect(find.byKey(const Key('key-1')), findsNothing);
    expect(find.textContaining('A manager must open it first'), findsOneWidget);
    expect(attendance.isClockedIn('ana'), isFalse,
        reason: 'a refused sign-in is not a day at work');
  });

  testWidgets('with no shift open a manager still signs in, and is clocked in',
      (t) async {
    await signIn(t, 'mo', '9999');

    expect(find.byType(TableFloorScreen), findsOneWidget);
    expect(attendance.isClockedIn('mo'), isTrue);
    expect(find.byKey(const Key('signed-in-clocked-in')), findsNothing,
        reason: 'the note fades by itself');
  });

  testWidgets('once the shift is open a cashier signs in and is clocked in',
      (t) async {
    ShiftStore(db).openShift(openingFloat: 100, cashierId: 'mo');

    await signIn(t, 'ana', '4321');

    expect(find.byType(TableFloorScreen), findsOneWidget);
    expect(attendance.isClockedIn('ana'), isTrue);
  });

  testWidgets('someone already on the clock is not clocked in twice',
      (t) async {
    ShiftStore(db).openShift(openingFloat: 100, cashierId: 'mo');
    final earlier = attendance.clockIn('ana');

    await signIn(t, 'ana', '4321');

    expect(attendance.openFor('ana')?.id, earlier.id);
  });
}
