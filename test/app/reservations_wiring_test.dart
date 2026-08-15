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
import 'package:offline_pos/core/db/reservation_store.dart';
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
import 'package:offline_pos/features/tables/reservations_screen.dart';
import 'package:offline_pos/features/tables/table_floor_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// Bookings as the shop uses them: taken on the floor of a real app shell, and
/// showing on the table they were promised.
///
/// A booking store nothing reads would pass its own tests and still leave a waiter
/// seating a walk-in on a table somebody rang about an hour ago.
void main() {
  late Db db;
  late ReservationStore book;
  late AuditLog audit;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    book = ReservationStore(db);
    audit = AuditLog(db);
    TableStore(db)
      ..add(name: '5')
      ..add(name: '6');
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
      config: const TillConfig(),
      reservations: book,
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
      if (find.byType(TableFloorScreen).evaluate().isNotEmpty) break;
    }
    await t.pumpAndSettle();
  }

  Future<void> openTheBook(WidgetTester t) async {
    await t.tap(find.byKey(const Key('floor-menu')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('floor-reservations')));
    await t.pumpAndSettle();
  }

  testWidgets('a booking taken on the floor lands on the table it promised',
      (t) async {
    await t.pumpWidget(app());
    await signIn(t);
    await openTheBook(t);

    expect(find.byType(ReservationsScreen), findsOneWidget);
    expect(find.byKey(const Key('reservations-empty')), findsOneWidget);

    await t.tap(find.byKey(const Key('reservation-add')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('reservation-name')), 'Ahmed');
    await t.enterText(find.byKey(const Key('reservation-phone')), '0100');
    await t.enterText(find.byKey(const Key('reservation-covers')), '4');
    // Twenty minutes out, so it is due on the floor rather than filed for later.
    final soon = DateTime.now().add(const Duration(minutes: 20));
    await t.enterText(find.byKey(const Key('reservation-time')),
        '${soon.hour.toString().padLeft(2, '0')}:'
        '${soon.minute.toString().padLeft(2, '0')}');
    await t.tap(find.byKey(const Key('reservation-table')));
    await t.pumpAndSettle();
    await t.tap(find.text('5').last);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('reservation-save')));
    await t.pumpAndSettle();

    final made = book.all().single;
    expect(made.name, 'Ahmed');
    expect(made.tableLabel, '5');
    expect(made.covers, 4);

    // Back on the plan, table 5 says it is spoken for and table 6 does not.
    await t.pageBack();
    await t.pumpAndSettle();
    final five = TableStore(db).all().firstWhere((x) => x.name == '5');
    final six = TableStore(db).all().firstWhere((x) => x.name == '6');
    expect(find.byKey(Key('table-booked-${five.id}')), findsOneWidget);
    expect(find.byKey(Key('table-booked-${six.id}')), findsNothing);
    expect(find.textContaining('Ahmed'), findsOneWidget);
  });

  testWidgets('a booking hours away does not hold a table on the plan', (t) async {
    book.save(Reservation(
      name: 'Later',
      tableLabel: '5',
      at: DateTime.now().toUtc().add(const Duration(hours: 5)),
    ));

    await t.pumpWidget(app());
    await signIn(t);

    final five = TableStore(db).all().firstWhere((x) => x.name == '5');
    expect(find.byKey(Key('table-booked-${five.id}')), findsNothing);
    // It is still in the book, which is where a booking that far out belongs.
    await openTheBook(t);
    expect(find.textContaining('Later'), findsOneWidget);
  });

  testWidgets('seating the guests takes the badge off the table', (t) async {
    final made = Reservation(
      name: 'Ahmed',
      tableLabel: '5',
      at: DateTime.now().toUtc().add(const Duration(minutes: 15)),
    );
    book.save(made);

    await t.pumpWidget(app());
    await signIn(t);
    final five = TableStore(db).all().firstWhere((x) => x.name == '5');
    expect(find.byKey(Key('table-booked-${five.id}')), findsOneWidget);

    await openTheBook(t);
    await t.tap(find.byKey(Key('reservation-${made.uuid}')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('reservation-seat')));
    await t.pumpAndSettle();
    await t.pageBack();
    await t.pumpAndSettle();

    expect(book.byUuid(made.uuid)!.state, ReservationState.seated);
    expect(find.byKey(Key('table-booked-${five.id}')), findsNothing);
  });
}
