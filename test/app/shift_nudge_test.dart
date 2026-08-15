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
import 'package:offline_pos/features/sell/sell_screen.dart';
import 'package:offline_pos/features/shift/shift_screen.dart';
import 'package:offline_pos/features/tables/table_floor_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// What a cashier is told about the drawer when they sign in.
///
/// Two ways a day goes wrong quietly: a Z with no float because nobody opened a
/// shift, and yesterday's shift silently swallowing today's sales. Both are told
/// on the screen the cashier actually lands on, and neither may stop them selling.
void main() {
  late Db db;
  late ShiftStore shifts;
  late AuditLog audit;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    shifts = ShiftStore(db);
    audit = AuditLog(db);
    SettingsStore(db);
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
      shifts: shifts,
      deviceId: 'till-1',
      endpoints: OdooEndpointStore(db),
      odoo: OdooWiring(outbox: outbox),
      tables: TableStore(db),
      settings: SettingsStore(db),
      customers: CustomerStore(db),
      attendance: AttendanceStore(db),
      config: const TillConfig(),
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
      if (find.byType(SellScreen).evaluate().isNotEmpty) break;
    }
    await t.pumpAndSettle();
  }

  testWidgets('signing in with no shift open nudges the cashier to open one',
      (t) async {
    await t.pumpWidget(app());
    await signIn(t);

    // On the floor, which is where sign-in lands, and readable there.
    expect(find.byType(TableFloorScreen), findsOneWidget);
    expect(find.byKey(const Key('shift-nudge')).hitTestable(), findsOneWidget);
    expect(find.text('No shift is open. Open one with a float?'), findsOneWidget);

    await t.tap(find.byKey(const Key('shift-nudge-open')));
    await t.pumpAndSettle();

    expect(find.byType(ShiftScreen), findsOneWidget);
    expect(find.byKey(const Key('open-shift')), findsOneWidget);
    // Taken, not just hidden behind the screen it opened.
    expect(find.byKey(const Key('shift-nudge')), findsNothing);
  });

  testWidgets('a shift left open from an earlier day says so', (t) async {
    shifts.openShift(
      openingFloat: 100,
      cashierId: 'sara',
      at: DateTime.now().toUtc().subtract(const Duration(days: 2)),
    );

    await t.pumpWidget(app());
    await signIn(t);

    expect(find.byKey(const Key('shift-nudge')).hitTestable(), findsOneWidget);
    expect(
        find.text('A shift is open from an earlier day. Close it first.'),
        findsOneWidget);

    // The way out is the shift screen, with the same drawer figures it always has.
    await t.tap(find.byKey(const Key('shift-nudge-open')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('close-shift')), findsOneWidget);
  });

  testWidgets("a shift opened today's trading is not nagged about", (t) async {
    shifts.openShift(openingFloat: 100, cashierId: 'sara');

    await t.pumpWidget(app());
    await signIn(t);

    expect(find.byKey(const Key('shift-nudge')), findsNothing);
  });

  testWidgets('the nudge informs and never blocks selling', (t) async {
    await t.pumpWidget(app());
    await signIn(t);

    // The floor is fully usable underneath it: start a takeaway with the banner up.
    await t.tap(find.byKey(const Key('floor-takeaway')));
    await t.pumpAndSettle();
    expect(find.byType(SellScreen), findsOneWidget);
    expect(find.byKey(const Key('shift-nudge')).hitTestable(), findsOneWidget);

    await t.tap(find.byKey(const Key('shift-nudge-dismiss')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('shift-nudge')), findsNothing);
  });

  testWidgets('an Arabic till reads the nudge in Arabic', (t) async {
    // The strip is built above the navigator, which is the one place in this app
    // where a missing Localizations ancestor would only show up on an Arabic till.
    SettingsStore(db).language = 'ar';

    await t.pumpWidget(app());
    await signIn(t);

    expect(find.text('لا توجد وردية مفتوحة. هل تفتح واحدة برصيد ابتدائي؟'),
        findsOneWidget);
  });

  testWidgets('the nudge does not follow the cashier out to the sign-in screen',
      (t) async {
    await t.pumpWidget(app());
    await signIn(t);
    expect(find.byKey(const Key('shift-nudge')).hitTestable(), findsOneWidget);

    // Off the floor and out: the next cashier's PIN screen is not the place to be
    // told about the last one's drawer.
    await t.tap(find.byKey(const Key('floor-takeaway')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('sign-out')));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('shift-nudge')), findsNothing);
    expect(find.byKey(const Key('user-sara')), findsOneWidget);
  });
}
