import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/config/till_config.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/schema.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/db/table_store.dart';
import 'package:offline_pos/core/lan/lan_credential.dart';
import 'package:offline_pos/core/lan/lan_peer.dart';
import 'package:offline_pos/core/lan/lan_transport.dart';
import 'package:offline_pos/core/lan/lan_wiring.dart';
import 'package:offline_pos/domain/order.dart';

import '../db/sqlite_loader.dart';
import 'shop.dart';

/// A datagram socket that goes nowhere, so the beacon's binds and closes can be
/// counted. The real thing is exercised over a loopback socket in the transport
/// tests; what matters here is the lifecycle around it.
class FakeDatagramSocket extends Stream<RawSocketEvent>
    implements RawDatagramSocket {
  final StreamController<RawSocketEvent> _events = StreamController();
  bool closed = false;

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
  void close() {
    closed = true;
    _events.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(useSystemSqlite);

  late Db db;
  setUp(() => db = Db.open(':memory:'));
  tearDown(() => db.close());

  test('a fresh till is off the LAN, and a sale on it is what it always was', () {
    // Exactly the decision main.dart makes, on a device nobody has configured and
    // a build given no dart-define.
    expect(SettingsStore(db).lanEnabled(fallback: const TillConfig().lanDefault),
        isFalse);

    // So no publish is wired, which is what keeps a one-till shop on the code path
    // it ran before the fabric existed.
    final orders = OrderStore(db, ownDeviceId: 'till-a');
    final order = heldOrder('till-a')
      ..state = OrderState.paid
      ..payments = [const OrderPayment(methodId: 1, amount: 100)];
    orders.save(order);

    expect(orders.byUuid(order.uuid)!.state, OrderState.paid);
    expect(orders.awaitingSync().single.uuid, order.uuid);
    // Not one row of fabric bookkeeping, and nothing that could have opened a socket.
    expect(db.raw.select('SELECT COUNT(*) c FROM lan_events').first['c'], 0);
    expect(db.raw.select('SELECT COUNT(*) c FROM lan_clocks').first['c'], 0);
  });

  test('a KDS build defaults to sharing, since it has nothing of its own to show',
      () {
    expect(const TillConfig(kdsMode: true).lanDefault, isTrue);
    expect(const TillConfig(lanFabric: true).lanDefault, isTrue);
    // And the device still has the last word either way.
    final settings = SettingsStore(db)..setLanEnabled(false);
    expect(settings.lanEnabled(fallback: true), isFalse);
  });

  test('an order replicated from a peer never enters this till\'s outbox', () {
    // The store main.dart builds, fed an order rung on another device the way the
    // applier feeds it.
    final orders = OrderStore(db, ownDeviceId: 'till-a');
    orders.save(heldOrder('till-b')..state = OrderState.paid, announce: false);

    expect(orders.awaitingSync(), isEmpty);
    expect(orders.held(), isEmpty);
    expect(SqliteOutboxStore(db).pendingCount, 0);
    // Only the kitchen sees it, which is the one thing a peer's ticket is for here.
    expect(orders.kitchenTickets().single.deviceId, 'till-b');
  });

  group('the node lifecycle', () {
    final sockets = <FakeDatagramSocket>[];
    late LanNode node;

    setUp(() {
      sockets.clear();
      node = LanNode.build(
        db: db,
        deviceId: 'till-a',
        deviceName: 'Front',
        shopKey: 'the-shop-key',
        orders: OrderStore(db, ownDeviceId: 'till-a'),
        tables: TableStore(db),
        audit: AuditLog(db),
        port: 0,
        beaconPort: 0,
        // No LAN address, so the HTTP server never binds: this is the same path a
        // till takes when its network is unplugged, and it keeps the lifecycle
        // assertions off a real socket.
        localAddresses: () async => const [],
        beaconBind: (_, _) async {
          final socket = FakeDatagramSocket();
          sockets.add(socket);
          return socket;
        },
      );
      addTearDown(node.dispose);
    });

    test('two callers starting at once bind one socket between them', () async {
      // Which is what the app shell and the LAN switch are: both may ask in the
      // same second, and two binds on one port is a device serving its peers from
      // whichever half won.
      await Future.wait([node.start(), node.start()]);
      await node.start();

      expect(sockets, hasLength(1));
      expect(node.isRunning, isTrue);
      // A device with no LAN address is on the LAN's terms, not serving.
      expect(node.servingAt, isNull);
    });

    test('switching off closes what was open, and switching on binds again',
        () async {
      await node.start();
      await node.stop();

      expect(sockets.single.closed, isTrue);
      expect(node.isRunning, isFalse);

      await node.start();
      // A new socket, and the old one was let go rather than leaked.
      expect(sockets, hasLength(2));
      expect(sockets.last.closed, isFalse);
      expect(node.isRunning, isTrue);
    });

    test('a device with the fabric off announces nothing and serves nothing', () {
      expect(sockets, isEmpty);
      expect(node.isRunning, isFalse);
      expect(node.servingAt, isNull);
    });
  });

  test('letting the client go is final, which is why coming off the LAN does not',
      () async {
    // The reason LanNode.stop leaves the HTTP client alone and only dispose closes
    // it: a closed client cannot be reopened, so closing it with the switch would
    // leave a device that came back on the LAN unable to reach anybody.
    final client = LanHttpClient(credential: LanCredential('the-shop-key'));
    client.close();

    await expectLater(
      client.fetch(
        LanPeer(
          deviceId: 'till-b',
          name: 'Back',
          host: '127.0.0.1',
          port: 45333,
          schemaVersion: Schema.version,
          lastSeenAt: DateTime.now().toUtc(),
        ),
        0,
      ),
      throwsA(isA<StateError>()),
    );
  });
}
