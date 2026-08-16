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
import 'package:offline_pos/core/db/schema.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/db/shift_store.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/db/table_store.dart';
import 'package:offline_pos/core/lan/lan_applier.dart';
import 'package:offline_pos/core/lan/lan_claim.dart';
import 'package:offline_pos/core/lan/lan_credential.dart';
import 'package:offline_pos/core/lan/lan_event.dart';
import 'package:offline_pos/core/lan/lan_event_log.dart';
import 'package:offline_pos/core/lan/lan_peer.dart';
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

/// The shop LAN with the switch taken out: requests reach the other till through
/// the same protocol handler a socket would deliver them to, and a till listed
/// unreachable answers the way a dead switch does.
class _Wire extends LanHttpClient {
  _Wire(this.owner, {required super.credential});

  /// The till that holds the tab, or null when nothing is answering out there.
  final LanProtocol? owner;

  @override
  Future<LanPage> fetch(LanPeer peer, int since) async => LanPage.empty;

  @override
  Future<void> notify(LanPeer peer, List<LanEvent> events, String deviceId) async {}

  @override
  Future<Map<String, dynamic>> claim(
    LanPeer peer, {
    required String orderUuid,
    required String deviceId,
    String? cashier,
  }) async {
    final protocol = owner;
    if (protocol == null) throw const SocketException('no route to the other till');
    final body = '{"device_id":"$deviceId","schema":${Schema.version},'
        '"order_uuid":"$orderUuid"}';
    final reply = protocol.handlePost(
      LanProtocol.claimPath,
      body,
      auth: LanCredential('the-shop-key')
          .stamp(method: 'POST', path: LanProtocol.claimPath, body: body),
    );
    if (reply.status == 409) throw LanTabRefused('${reply.body['error']}');
    if (reply.status != 200) {
      throw HttpException('${reply.status} from the other till: ${reply.body}');
    }
    return (reply.body['order'] as Map).cast<String, dynamic>();
  }
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

/// Taking over a tab, as a cashier does it: tap the busy table on the floor of a
/// real app shell, agree, clear the manager gate, and settle a bill the other till
/// opened.
///
/// The protocol itself is proven in test/lan/lan_takeover_test.dart. What is proven
/// here is that the shell asks, that the manager gate is in front of it, and above
/// all that a till which does not answer means the tab stays where it is: a
/// takeover that quietly succeeded against a dead peer would be a bill settled
/// twice, and every unit test would still pass.
void main() {
  late Db db;
  late Db peerDb;
  late OrderStore orders;
  late OrderStore peerOrders;
  late SettingsStore settings;
  late SettingsStore peerSettings;
  late AuditLog audit;
  late LanProtocol peerProtocol;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    // The till refuses to start an order with no shift open, so a test that
    // sells opens the drawer first.
    ShiftStore(db).openShift(openingFloat: 100, cashierId: 'sara');
    peerDb = Db.open(':memory:');
    orders = OrderStore(db, ownDeviceId: 'till-1');
    settings = SettingsStore(db);
    audit = AuditLog(db);

    peerOrders = OrderStore(peerDb, ownDeviceId: 'till-2');
    peerSettings = SettingsStore(peerDb)..lanAllowTakeover = true;
    peerProtocol = LanProtocol(
      deviceId: 'till-2',
      log: LanEventLog(peerDb, deviceId: 'till-2'),
      applier: LanApplier(
        deviceId: 'till-2',
        orders: peerOrders,
        tables: TableStore(peerDb),
        settings: peerSettings,
        reservations: ReservationStore(peerDb),
        log: LanEventLog(peerDb, deviceId: 'till-2'),
      ),
      credential: LanCredential('the-shop-key'),
      claims: LanClaimDesk(
        deviceId: 'till-2',
        orders: peerOrders,
        allowed: () => peerSettings.lanAllowTakeover,
      ),
    );

    TableStore(db).add(name: '5');
    settings.lanAllowTakeover = true;
    // A manager, so the takeover gate passes without a PIN dialog in the way of the
    // wiring this file is about. The gate itself has its own test below.
    await AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'sara', name: 'Sara', pin: '1234', role: 'manager');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');
  });
  tearDown(() {
    db.close();
    peerDb.close();
  });

  /// The tab the other till parked on table 5, as both devices hold it: owned there,
  /// replicated here.
  Order tabOnTheOtherTill() {
    final tab = Order(
      deviceId: 'till-2',
      cashierId: 'omar',
      type: OrderType.dineIn,
      tableLabel: '5',
    )
      ..state = OrderState.held
      ..lines.add(OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 100));
    peerOrders.save(tab, announce: false);
    orders.save(tab, announce: false);
    return tab;
  }

  LanNode node({bool peerReachable = true, bool peerVisible = true}) {
    final built = LanNode.build(
      db: db,
      deviceId: 'till-1',
      deviceName: 'Counter',
      shopKey: 'the-shop-key',
      orders: orders,
      tables: TableStore(db),
      settings: settings,
      reservations: ReservationStore(db),
      audit: audit,
      port: 0,
      beaconPort: 0,
      localAddresses: () async => const [],
      beaconBind: (_, _) async => _FakeBeaconSocket(),
      client: _Wire(peerReachable ? peerProtocol : null,
          credential: LanCredential('the-shop-key')),
    );
    if (peerVisible) {
      built.peers.seen(LanPeer(
        deviceId: 'till-2',
        name: 'Handheld',
        host: '10.0.0.2',
        port: 45333,
        schemaVersion: Schema.version,
        lastSeenAt: DateTime.now().toUtc(),
      ));
    }
    return built;
  }

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
      shifts: ShiftStore(db),
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

  /// Tap the busy table on the floor the app lands on after sign-in.
  Future<void> tapTableFive(WidgetTester t) async {
    final tile = find.byWidgetPredicate((w) =>
        w is InkWell && '${w.key}'.startsWith('[<\'table-tile-'));
    await t.tap(tile.first);
    await t.pumpAndSettle();
  }

  testWidgets('the counter takes over a tab the other till parked', (t) async {
    final tab = tabOnTheOtherTill();
    final lan = node();

    await t.pumpWidget(app(lan));
    await signIn(t);
    await tapTableFive(t);

    expect(find.byKey(const Key('confirm-takeover')), findsOneWidget);
    await t.tap(find.byKey(const Key('confirm-takeover')));
    await t.pumpAndSettle();

    // The bill is on this till's counter, and the other till has let it go.
    expect(orders.byUuid(tab.uuid)!.deviceId, 'till-1');
    expect(orders.held(), isEmpty, reason: 'it is recalled, not left parked');
    expect(peerOrders.held(), isEmpty);
    expect(find.byType(SellScreen), findsOneWidget);
    expect(find.text('Pizza'), findsWidgets);
    await lan.dispose();
  });

  testWidgets('a till that does not answer keeps its tab', (t) async {
    final tab = tabOnTheOtherTill();
    final lan = node(peerReachable: false);

    await t.pumpWidget(app(lan));
    await signIn(t);
    await tapTableFive(t);
    await t.tap(find.byKey(const Key('confirm-takeover')));
    await t.pumpAndSettle();

    expect(orders.byUuid(tab.uuid)!.deviceId, 'till-2',
        reason: 'a till that cannot be asked cannot let go');
    expect(peerOrders.held().map((o) => o.uuid), [tab.uuid]);
    expect(find.textContaining('did not answer'), findsOneWidget);
    await lan.dispose();
  });

  testWidgets('a till that says no is told apart from one that says nothing',
      (t) async {
    final tab = tabOnTheOtherTill();
    // The other till answers, and its answer is no.
    peerSettings.lanAllowTakeover = false;
    final lan = node();

    await t.pumpWidget(app(lan));
    await signIn(t);
    await tapTableFive(t);
    await t.tap(find.byKey(const Key('confirm-takeover')));
    await t.pumpAndSettle();

    expect(find.textContaining('would not hand the tab over'), findsOneWidget);
    expect(find.textContaining('did not answer'), findsNothing);
    expect(orders.byUuid(tab.uuid)!.deviceId, 'till-2');
    expect(peerOrders.held().map((o) => o.uuid), [tab.uuid]);
    await lan.dispose();
  });

  testWidgets('backing out of the confirmation leaves the tab alone', (t) async {
    final tab = tabOnTheOtherTill();
    final lan = node();

    await t.pumpWidget(app(lan));
    await signIn(t);
    await tapTableFive(t);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();

    expect(orders.byUuid(tab.uuid)!.deviceId, 'till-2');
    expect(peerOrders.held().map((o) => o.uuid), [tab.uuid]);
    await lan.dispose();
  });

  testWidgets('with takeovers off the floor still says settle it there', (t) async {
    final tab = tabOnTheOtherTill();
    settings.lanAllowTakeover = false;
    final lan = node();

    await t.pumpWidget(app(lan));
    await signIn(t);
    await tapTableFive(t);

    expect(find.byKey(const Key('confirm-takeover')), findsNothing);
    expect(find.textContaining('Settle it there'), findsOneWidget);
    expect(orders.byUuid(tab.uuid)!.deviceId, 'till-2');
    await lan.dispose();
  });

  testWidgets('a cashier without a manager cannot take a tab over', (t) async {
    await AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'ana', name: 'Ana', pin: '4321');
    WizardStore(db).dismiss(WizardId.firstSale, 'ana');
    final tab = tabOnTheOtherTill();
    final lan = node();

    await t.pumpWidget(app(lan));
    await t.tap(find.byKey(const Key('user-ana')));
    await t.pumpAndSettle();
    for (final d in '4321'.split('')) {
      await t.tap(find.byKey(Key('key-$d')));
      await t.pump();
    }
    await t.tap(find.byKey(const Key('pin-ok')));
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 50));
      if (find.byType(TableFloorScreen).evaluate().isNotEmpty) break;
    }
    await t.pumpAndSettle();
    await tapTableFive(t);
    await t.tap(find.byKey(const Key('confirm-takeover')));
    await t.pumpAndSettle();

    // The manager PIN dialog is in the way, and walking away from it changes
    // nothing on either till.
    expect(find.byKey(const Key('manager-pin')), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(orders.byUuid(tab.uuid)!.deviceId, 'till-2');
    expect(peerOrders.held().map((o) => o.uuid), [tab.uuid]);
    await lan.dispose();
  });
}
