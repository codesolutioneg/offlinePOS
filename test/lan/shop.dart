import 'dart:convert';

import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/schema.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/db/table_store.dart';
import 'package:offline_pos/core/lan/lan_applier.dart';
import 'package:offline_pos/core/lan/lan_claim.dart';
import 'package:offline_pos/core/lan/lan_credential.dart';
import 'package:offline_pos/core/lan/lan_event.dart';
import 'package:offline_pos/core/lan/lan_event_log.dart';
import 'package:offline_pos/core/lan/lan_fabric.dart';
import 'package:offline_pos/core/lan/lan_peer.dart';
import 'package:offline_pos/core/lan/lan_transport.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/domain/order.dart';

/// A test clock that moves one second per read, so the last-write-wins rule is
/// decided by the order things happened in and not by how fast the machine is.
class StepClock {
  StepClock([DateTime? from])
      : _at = from ?? DateTime.utc(2026, 1, 1, 9);

  DateTime _at;

  DateTime call() {
    _at = _at.add(const Duration(seconds: 1));
    return _at;
  }
}

/// One device on the test LAN: its own encrypted-in-production database, its
/// stores, its event log and its half of the fabric.
///
/// Wired exactly the way main.dart wires a real till, so what these tests prove
/// about replication is a property of the shipped composition and not of a
/// convenient stand-in.
class TestTill {
  TestTill(
    this.deviceId, {
    required this.shop,
    required String shopKey,
    String? name,
    StepClock? clock,
  })  : name = name ?? deviceId,
        credential = LanCredential(shopKey),
        clock = clock ?? StepClock() {
    db = Db.open(':memory:');
    log = LanEventLog(db, deviceId: deviceId, now: () => this.clock());
    audit = AuditLog(db);
    outboxStore = SqliteOutboxStore(db);
    outbox = Outbox(store: outboxStore, senders: {});
    orders = OrderStore(
      db,
      ownDeviceId: deviceId,
      publish: (kind, uuid, payload) => fabric.publish(kind, uuid, payload),
    );
    tables = TableStore(
      db,
      publish: (kind, uuid, payload) => fabric.publish(kind, uuid, payload),
    );
    settings = SettingsStore(db)
      ..publish = (kind, uuid, payload) => fabric.publish(kind, uuid, payload);
    applier = LanApplier(
      deviceId: deviceId,
      orders: orders,
      tables: tables,
      settings: settings,
      log: log,
      onRefused: (event, detail) => refusals.add('$event: $detail'),
    );
    claims = LanClaimDesk(
      deviceId: deviceId,
      orders: orders,
      allowed: () => settings.lanAllowTakeover,
      audit: (event, detail) => audited.add('$event: $detail'),
    );
    protocol = LanProtocol(
      deviceId: deviceId,
      log: log,
      applier: applier,
      credential: credential,
      claims: claims,
      onRefused: (event, detail) => refusals.add('$event: $detail'),
    );
    peers = LanPeerDirectory(log: (event, detail) => refusals.add('$event: $detail'));
    fabric = LanFabric(
      deviceId: deviceId,
      log: log,
      applier: applier,
      peers: peers,
      fetch: (peer, since) => shop.fetch(deviceId, peer, since),
      notify: (peer, events) => shop.notify(deviceId, peer, events),
      onError: (event, detail) => errors.add('$event: $detail'),
    );
  }

  final String deviceId;
  final String name;
  final TestShop shop;
  final StepClock clock;

  /// This till's half of the pairing. Tests reach for it to stamp a request the way
  /// the real client does, or hand a different one to play the guest laptop.
  final LanCredential credential;

  late final Db db;
  late final LanEventLog log;
  late final AuditLog audit;
  late final SqliteOutboxStore outboxStore;
  late final Outbox outbox;
  late final OrderStore orders;
  late final TableStore tables;
  late final SettingsStore settings;
  late final LanApplier applier;
  late final LanClaimDesk claims;
  late final LanProtocol protocol;
  late final LanPeerDirectory peers;
  late final LanFabric fabric;

  /// Events and peers this till turned away, and pull/notify failures it logged.
  final List<String> refusals = [];
  final List<String> errors = [];

  /// What this till put in the audit trail about tabs changing hands, on either
  /// side of the handover.
  final List<String> audited = [];

  void close() => db.close();
}

/// A shop LAN made of in-memory tills.
///
/// Requests go through the same JSON encode and decode a socket would, so the wire
/// format is exercised rather than assumed; only the socket itself is missing.
class TestShop {
  TestShop({this.shopKey = 'the-shop-key'});

  /// The key every till in this shop is paired on. A test that wants an outsider adds
  /// a till with a different one.
  final String shopKey;

  final Map<String, TestTill> tills = {};

  /// Device ids that cannot currently be reached, so a partition can be opened and
  /// healed inside a test.
  final Set<String> unreachable = {};

  /// Peers that raise on every request, standing in for a till whose app is up but
  /// whose fabric is broken.
  final Set<String> throwing = {};

  TestTill add(String deviceId, {String? name, StepClock? clock, String? shopKey}) {
    final till = TestTill(deviceId,
        shop: this, name: name, clock: clock, shopKey: shopKey ?? this.shopKey);
    tills[deviceId] = till;
    return till;
  }

  /// Introduce every till to every other one, as the beacon would.
  void introduceAll({int schemaVersion = -1}) {
    for (final a in tills.values) {
      for (final b in tills.values) {
        if (a.deviceId == b.deviceId) continue;
        a.peers.seen(peerFor(b, schemaVersion: schemaVersion));
      }
    }
  }

  LanPeer peerFor(TestTill till, {int schemaVersion = -1}) => LanPeer(
        deviceId: till.deviceId,
        name: till.name,
        host: '10.0.0.1',
        port: 45333,
        schemaVersion: schemaVersion < 0 ? Schema.version : schemaVersion,
        lastSeenAt: DateTime.utc(2026, 1, 1, 9),
      );

  Future<LanPage> fetch(String from, LanPeer peer, int since) async {
    final till = _reach(from, peer);
    final query = {'since': '$since', 'schema': '${Schema.version}'};
    final reply = till.protocol.handleGet(
      LanProtocol.eventsPath,
      query,
      auth: _stamp(from,
          method: 'GET',
          path: LanProtocol.eventsPath,
          query: LanCredential.canonicalQuery(query)),
    );
    if (reply.status != 200) {
      throw StateError('${peer.deviceId} answered ${reply.status}');
    }
    final body = _overTheWire(reply.body);
    return LanPage(
      events: [
        for (final e in body['events'] as List)
          LanEvent.fromMap((e as Map).cast<String, dynamic>()),
      ],
      highSeq: body['high_seq'] as int,
    );
  }

  Future<void> notify(String from, LanPeer peer, List<LanEvent> events) async {
    final till = _reach(from, peer);
    final body = jsonEncode({
      'device_id': from,
      'schema': Schema.version,
      'events': [for (final e in events) e.toMap()],
    });
    final reply = till.protocol.handlePost(
      LanProtocol.notifyPath,
      body,
      auth: _stamp(from,
          method: 'POST', path: LanProtocol.notifyPath, body: body),
    );
    if (reply.status != 200) {
      throw StateError('${peer.deviceId} answered ${reply.status}');
    }
  }

  /// One till asking another for a parked tab, over the same JSON, the same stamp
  /// and the same handler a socket would carry it to. Answers with what the claimer
  /// wrote, or null when the owner refused or could not be reached.
  Future<Order?> claim(String from, TestTill owner, String orderUuid,
      {String? cashier}) async {
    final peer = peerFor(owner);
    final body = jsonEncode({
      'device_id': from,
      'schema': Schema.version,
      'order_uuid': orderUuid,
      'cashier': ?cashier,
    });
    final till = _reach(from, peer);
    final reply = till.protocol.handlePost(
      LanProtocol.claimPath,
      body,
      auth: _stamp(from, method: 'POST', path: LanProtocol.claimPath, body: body),
    );
    if (reply.status != 200) return null;
    final payload = _overTheWire(reply.body)['order'] as Map;
    return tills[from]!
        .claims
        .accept(payload.cast<String, dynamic>(), cashier: cashier);
  }

  /// A notify from a till claiming a schema version this shop does not run, as an
  /// unfinished rollout would send. Returns the status so a test can assert on the
  /// refusal instead of on an exception.
  int notifyOnSchema(
      String from, LanPeer peer, List<LanEvent> events, int schemaVersion) {
    final body = jsonEncode({
      'device_id': from,
      'schema': schemaVersion,
      'events': [for (final e in events) e.toMap()],
    });
    return tills[peer.deviceId]!
        .protocol
        .handlePost(
          LanProtocol.notifyPath,
          body,
          auth: _stamp(from,
              method: 'POST', path: LanProtocol.notifyPath, body: body),
        )
        .status;
  }

  /// The stamp the calling till would put on this request, so every hop in this
  /// harness goes through the same pairing check a real one does.
  String? _stamp(
    String from, {
    required String method,
    required String path,
    String query = '',
    String body = '',
  }) =>
      tills[from]
          ?.credential
          .stamp(method: method, path: path, query: query, body: body);

  /// A cut cable cuts both ways, so a till listed unreachable can neither be
  /// reached nor reach out. A one-sided partition would let a test pass on a
  /// convergence it never actually had to do.
  TestTill _reach(String from, LanPeer peer) {
    if (throwing.contains(peer.deviceId)) {
      throw StateError('${peer.deviceId} is broken');
    }
    if (unreachable.contains(peer.deviceId) || unreachable.contains(from)) {
      throw StateError('${peer.deviceId} is unreachable from $from');
    }
    return tills[peer.deviceId]!;
  }

  /// Every field as it would come back off a socket, so a payload that only works
  /// because both ends share one Dart object cannot pass.
  Map<String, dynamic> _overTheWire(Map<String, dynamic> body) =>
      (jsonDecode(jsonEncode(body)) as Map).cast<String, dynamic>();

  /// Run passes until nothing changes, the way the timers would.
  Future<void> settle({int rounds = 4}) async {
    for (var i = 0; i < rounds; i++) {
      for (final till in tills.values) {
        await till.fabric.pass();
      }
    }
  }

  void close() {
    for (final till in tills.values) {
      till.close();
    }
  }
}

/// A parked dine-in order, the shape a real hold produces.
Order heldOrder(String deviceId, {String table = '5', String item = 'Pizza'}) => Order(
      deviceId: deviceId,
      cashierId: 'ana',
      tableLabel: table,
    )
  ..state = OrderState.held
  ..lines.add(OrderLine(productId: 1, name: item, quantity: 1, unitPrice: 100));
