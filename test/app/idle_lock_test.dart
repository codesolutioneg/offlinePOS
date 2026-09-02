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

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async =>
      const [];
}

/// The idle lock: an unattended till drops back to the PIN screen on its own,
/// so nobody passing can play with the drawer or the menu.
void main() {
  late Db db;
  late AuditLog audit;
  late SettingsStore settings;

  /// The clock the lock reads, advanced by hand alongside the pumped time,
  /// because the widget clock in a test does not move with pump().
  late DateTime now;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    now = DateTime(2026, 9, 2, 12);
    audit = AuditLog(db);
    settings = SettingsStore(db);
    ShiftStore(db).openShift(openingFloat: 100, cashierId: 'sara');
    await AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'sara', name: 'Sara', pin: '1234', role: 'manager');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');
  });
  tearDown(() => db.close());

  Widget app() {
    final outbox = Outbox(store: SqliteOutboxStore(db), senders: {});
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
      nowFn: () => now,
    );
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
      if (find.byKey(const Key('pin-ok')).evaluate().isEmpty) break;
    }
    await t.pumpAndSettle();
  }

  /// Let [minutes] pass on both clocks: the injected one the lock compares
  /// against, and the pumped one that fires the background tick.
  Future<void> idle(WidgetTester t, int minutes) async {
    now = now.add(Duration(minutes: minutes));
    await t.pump(Duration(minutes: minutes));
    await t.pumpAndSettle();
  }

  testWidgets('an untouched till locks back to the PIN screen', (t) async {
    await t.pumpWidget(app());
    await signIn(t);
    expect(find.byKey(const Key('user-sara')), findsNothing,
        reason: 'signed in: the roster is off screen');

    await idle(t, 6);

    expect(find.byKey(const Key('user-sara')), findsOneWidget,
        reason: 'five untouched minutes lock the till');
    expect(audit.recent(event: 'till.locked'), isNotEmpty,
        reason: 'the lock leaves its own audit trail');
  });

  testWidgets('a touch holds the lock off', (t) async {
    await t.pumpWidget(app());
    await signIn(t);

    // Three quiet minutes, then a touch, then three more: never five straight.
    await idle(t, 3);
    await t.tapAt(const Offset(400, 300));
    await idle(t, 3);

    expect(find.byKey(const Key('user-sara')), findsNothing,
        reason: 'the touch restarted the idle clock');
  });

  testWidgets('switched off, the till stays open however long it sits',
      (t) async {
    settings.idleLockMinutes = 0;
    await t.pumpWidget(app());
    await signIn(t);

    await idle(t, 30);

    expect(find.byKey(const Key('user-sara')), findsNothing);
  });
}
