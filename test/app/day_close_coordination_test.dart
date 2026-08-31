import 'dart:async';
import 'dart:io';

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
import 'package:offline_pos/core/db/table_assignment_store.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/db/shift_store.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/db/table_store.dart';
import 'package:offline_pos/core/lan/lan_credential.dart';
import 'package:offline_pos/core/lan/lan_event.dart';
import 'package:offline_pos/core/lan/lan_peer.dart';
import 'package:offline_pos/core/lan/lan_shift_board.dart';
import 'package:offline_pos/core/lan/lan_transport.dart';
import 'package:offline_pos/core/lan/lan_wiring.dart';
import 'package:offline_pos/core/onboarding/wizard_id.dart';
import 'package:offline_pos/core/onboarding/wizard_store.dart';
import 'package:offline_pos/core/printing/printer_discovery.dart';
import 'package:offline_pos/core/printing/printer_registry.dart';
import 'package:offline_pos/core/sync/odoo_endpoint.dart';
import 'package:offline_pos/core/sync/odoo_wiring.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/core/sync/sync_service.dart';
import 'package:offline_pos/domain/business_day.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/sell/sell_screen.dart';
import 'package:offline_pos/features/tables/table_floor_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// A LAN with nothing on the other end: enough to assemble a node, never enough to
/// reach anybody, which is also the state a shop is in when its switch dies.
class _Quiet extends LanHttpClient {
  _Quiet({required super.credential});

  @override
  Future<LanPage> fetch(LanPeer peer, int since) async => LanPage.empty;

  @override
  Future<void> notify(LanPeer peer, List<LanEvent> events, String deviceId) async {}
}

class _FakeBeaconSocket extends Stream<RawSocketEvent>
    implements RawDatagramSocket {
  final StreamController<RawSocketEvent> _events = StreamController();

  @override
  StreamSubscription<RawSocketEvent> listen(
    void Function(RawSocketEvent event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      _events.stream.listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  bool broadcastEnabled = false;

  @override
  int send(List<int> buffer, InternetAddress address, int port) => buffer.length;

  @override
  void close() => _events.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The day closed on the other till, as this one experiences it.
///
/// The rule the whole feature is bound by is the last test in this file: a device
/// that hears nothing sells exactly as it always did. Everything else here is what
/// a shop that asked for the coordination gets.
void main() {
  late Db db;
  late OrderStore orders;
  late SettingsStore settings;
  late ShiftStore shifts;
  late AuditLog audit;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    orders = OrderStore(db, ownDeviceId: 'till-1');
    settings = SettingsStore(db);
    shifts = ShiftStore(db);
    audit = AuditLog(db);
    TableStore(db)
      ..add(name: '5')
      ..add(name: '6');
    shifts.openShift(openingFloat: 100, cashierId: 'sara');
    await AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'sara', name: 'Sara', pin: '1234', role: 'manager');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');
  });
  tearDown(() => db.close());

  /// The other till having closed today, as the applier would have left it.
  void theOtherTillClosedToday() =>
      LanShiftBoard(settings).remember(LanShiftNotice(
        deviceId: 'till-2',
        deviceName: 'Bar',
        businessDate: BusinessDay.of(DateTime.now().toUtc()).key,
        at: DateTime.now().toUtc(),
      ));

  LanNode node() => LanNode.build(
        db: db,
        deviceId: 'till-1',
        deviceName: 'Counter',
        shopKey: () => 'the-shop-key',
        orders: orders,
        tables: TableStore(db),
        settings: settings,
        reservations: ReservationStore(db),
        assignments: TableAssignmentStore(db),
        audit: audit,
        port: 0,
        beaconPort: 0,
        localAddresses: () async => const [],
        beaconBind: (_, _) async => _FakeBeaconSocket(),
        client: _Quiet(credential: LanCredential('the-shop-key')),
      );

  Widget app(LanNode? lan) {
    final outbox = Outbox(store: SqliteOutboxStore(db), senders: {});
    return PosApp(
      auth: AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit),
      users: UserStore(db),
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
      shifts: shifts,
      deviceId: 'till-1',
      endpoints: OdooEndpointStore(db),
      odoo: OdooWiring(outbox: outbox),
      tables: TableStore(db),
      settings: settings,
      customers: CustomerStore(db),
      attendance: AttendanceStore(db),
      config: const TillConfig(),
      lan: lan,
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

  testWidgets('with the warning on, the floor says so and still sells', (t) async {
    LanShiftBoard(settings).policy = LanDayClosePolicy.warn;
    theOtherTillClosedToday();
    final lan = node();

    await t.pumpWidget(app(lan));
    await signIn(t);

    expect(find.byKey(const Key('floor-day-notice')), findsOneWidget);
    expect(find.textContaining('Bar'), findsOneWidget);
    // A warning is a warning: the till carries on trading.
    await t.tap(find.byKey(const Key('floor-takeaway')));
    await t.pumpAndSettle();
    expect(find.byType(SellScreen), findsOneWidget);
    await lan.dispose();
  });

  testWidgets('with holding on, new work waits but an open tab is still settled',
      (t) async {
    LanShiftBoard(settings).policy = LanDayClosePolicy.block;
    theOtherTillClosedToday();
    // A tab already running on table 5, which somebody is waiting to pay for.
    final tab = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      type: OrderType.dineIn,
      tableLabel: '5',
    )
      ..state = OrderState.held
      ..lines.add(OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 100));
    orders.save(tab, announce: false);
    final lan = node();

    await t.pumpWidget(app(lan));
    await signIn(t);
    expect(find.byKey(const Key('floor-day-notice')), findsOneWidget);

    // A new takeaway is held.
    await t.tap(find.byKey(const Key('floor-takeaway')));
    await t.pumpAndSettle();
    expect(find.byType(SellScreen), findsNothing);
    expect(find.textContaining('New orders are held'), findsWidgets);

    // The tab that is already open is not: money that has been ordered has to be
    // takeable whatever the policy says.
    final five = TableStore(db).all().firstWhere((x) => x.name == '5');
    await t.tap(find.byKey(Key('table-tile-${five.id}')));
    await t.pumpAndSettle();
    expect(find.byType(SellScreen), findsOneWidget);
    expect(orders.byUuid(tab.uuid)!.state, OrderState.draft);
    await lan.dispose();
  });

  testWidgets('a free table is new work too, and is held', (t) async {
    LanShiftBoard(settings).policy = LanDayClosePolicy.block;
    theOtherTillClosedToday();
    final lan = node();

    await t.pumpWidget(app(lan));
    await signIn(t);
    final six = TableStore(db).all().firstWhere((x) => x.name == '6');
    await t.tap(find.byKey(Key('table-tile-${six.id}')));
    await t.pumpAndSettle();

    expect(find.byType(SellScreen), findsNothing);
    await lan.dispose();
  });

  testWidgets('a device with no fabric sells exactly as it always did', (t) async {
    // The notice is on disk from when this till was last on the LAN, the policy is
    // the strictest one, and the fabric is not there. Nothing may be held: a shop
    // that cannot see its network still has to be able to trade.
    LanShiftBoard(settings).policy = LanDayClosePolicy.block;
    theOtherTillClosedToday();

    await t.pumpWidget(app(null));
    await signIn(t);

    expect(find.byKey(const Key('floor-day-notice')), findsNothing);
    await t.tap(find.byKey(const Key('floor-takeaway')));
    await t.pumpAndSettle();
    expect(find.byType(SellScreen), findsOneWidget);
  });

  testWidgets('nothing is said while the shop has asked for nothing', (t) async {
    theOtherTillClosedToday();
    final lan = node();

    await t.pumpWidget(app(lan));
    await signIn(t);

    expect(find.byKey(const Key('floor-day-notice')), findsNothing);
    await lan.dispose();
  });

  testWidgets('closing the day here tells the rest of the shop', (t) async {
    final lan = node();
    await t.pumpWidget(app(lan));
    await signIn(t);

    // The cash-up, as a cashier does it: off the floor, into the shift screen, count
    // the drawer, confirm.
    await t.tap(find.byKey(const Key('floor-takeaway')));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Open navigation menu'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-shift')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('close-shift')));
    await t.pumpAndSettle();
    for (final d in ['1', '0', '0']) {
      await t.tap(find.byKey(Key('key-$d')));
      await t.pump();
    }
    await t.tap(find.byKey(const Key('keypad-ok')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-close-shift')));
    await t.pumpAndSettle();

    expect(shifts.currentOpenShift(), isNull);
    // One event in this till's own log, which is what a peer pulls. Announced after
    // the drawer was counted, so the cash-up never waited on it.
    final kinds = db.raw
        .select('SELECT kind FROM lan_events')
        .map((r) => r['kind'] as String)
        .toList();
    expect(kinds, contains(LanEventKind.shiftLifecycle.wire));
    await lan.dispose();
  });

  testWidgets('once this till has closed too, it stops being nudged', (t) async {
    LanShiftBoard(settings).policy = LanDayClosePolicy.block;
    theOtherTillClosedToday();
    shifts.closeShift(countedCash: 100);
    final lan = node();

    await t.pumpWidget(app(lan));
    await signIn(t);

    expect(find.byKey(const Key('floor-day-notice')), findsNothing);
    await lan.dispose();
  });
}
