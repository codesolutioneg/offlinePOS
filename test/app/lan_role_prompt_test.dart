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

/// The Primary / Join / Skip question a till asks the first time somebody signs
/// in on it.
///
/// It is raised from the app shell rather than from a screen, so it has to be
/// opened on the navigator the MaterialApp builds. Asking on the shell's own
/// context finds no MaterialLocalizations and throws on the one sign-in every
/// new till performs, which no other test here would notice.
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
    await AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'sara', name: 'Sara', pin: '1234', role: 'manager');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');
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

  Future<void> signIn(WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1280, 1600));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('user-sara')));
    await t.pump();
    for (final d in '1234'.split('')) {
      await t.tap(find.byKey(Key('key-$d')));
      await t.pump();
    }
    await t.tap(find.byKey(const Key('pin-ok')));
    for (var i = 0; i < 30; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
  }

  testWidgets('a till with no role yet asks who it is, without throwing',
      (t) async {
    await signIn(t);

    expect(takenException(t), isNull);
    expect(find.byKey(const Key('lan-role-prompt')), findsOneWidget);
    expect(find.byKey(const Key('lan-role-prompt-primary')), findsOneWidget);
    expect(find.byKey(const Key('lan-role-prompt-join')), findsOneWidget);
    expect(find.byKey(const Key('lan-role-prompt-skip')), findsOneWidget);
  });

  testWidgets('a till that already answered is not asked again', (t) async {
    settings.lanRolePromptDismissed = true;

    await signIn(t);

    expect(takenException(t), isNull);
    expect(find.byKey(const Key('lan-role-prompt')), findsNothing);
  });

  // Every answer carries on in the shell, so each one needs the same context
  // the question was asked on. Answering used to throw where asking did.
  for (final answer in const ['primary', 'join', 'skip']) {
    testWidgets('answering $answer is carried out without throwing', (t) async {
      await signIn(t);

      await t.tap(find.byKey(Key('lan-role-prompt-$answer')));
      for (var i = 0; i < 30; i++) {
        await t.pump(const Duration(milliseconds: 16));
      }

      expect(takenException(t), isNull);
      expect(settings.lanRolePromptDismissed, isTrue);
    });
  }
}

/// The exception the binding caught, if any. A dialog opened on the wrong
/// context fails here rather than at the assertion, so the test has to look.
Object? takenException(WidgetTester t) =>
    t.binding.takeException() as Object?;
