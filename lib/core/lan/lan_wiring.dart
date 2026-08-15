import 'dart:async';
import 'dart:io';

import '../audit/audit_log.dart';
import '../db/database.dart';
import '../db/order_store.dart';
import '../db/settings_store.dart';
import '../db/table_store.dart';
import 'lan_applier.dart';
import 'lan_beacon.dart';
import 'lan_event.dart';
import 'lan_credential.dart';
import 'lan_event_log.dart';
import 'lan_fabric.dart';
import 'lan_peer.dart';
import 'lan_transport.dart';

/// Everything the shop network screen reports about this device.
///
/// Read on every rebuild rather than handed over once, because all of it changes
/// while somebody is looking at it: the beacon finds a device, a pull fails, a
/// cursor moves. A peer list frozen when the screen opened is a support screen that
/// lies, which is worse than no screen at all.
typedef LanFacts = ({
  String? servingAt,
  List<LanPeer> peers,
  List<LanPeer> refused,
  Map<String, int> cursors,
  DateTime? lastPassAt,
  String? lastError,
});

/// This device's whole presence on the shop LAN: the log it serves, the beacon it
/// announces on, the server peers pull from and the replicator that keeps it level
/// with them.
///
/// Assembled in one place so main.dart reads as one decision (is the fabric on)
/// rather than five, and so nothing is half-wired: a till with a beacon and no
/// applier would announce itself and then ignore everyone.
class LanNode {
  LanNode({
    required this.deviceId,
    required this.deviceName,
    required LanEventLog log,
    required LanFabric fabric,
    required LanHost host,
    required LanBeacon beacon,
    required LanHttpClient client,
    required this.peers,
  })  : _log = log,
        _fabric = fabric,
        _host = host,
        _beacon = beacon,
        _client = client;

  /// Builds every part and joins them up. Nothing binds or announces until
  /// [start] is called.
  factory LanNode.build({
    required Db db,
    required String deviceId,
    required String deviceName,
    /// The shop's shared key. Required rather than optional so a fabric can never be
    /// assembled without one: an unauthenticated till would serve the shop's tabs to
    /// any device on the subnet.
    required String shopKey,
    required OrderStore orders,
    required TableStore tables,
    required SettingsStore settings,
    required AuditLog audit,
    required int port,
    required int beaconPort,
    // The seams LanHost and LanBeacon already take, passed through so a suite can
    // prove this assembly binds, lets go and binds again without touching a real
    // shop network. Null everywhere on a till, which is the whole point.
    Future<List<String>> Function()? localAddresses,
    Future<RawDatagramSocket> Function(InternetAddress address, int port)?
        beaconBind,
  }) {
    // Every fabric refusal, dead peer and failed announce lands in the audit trail
    // under 'system', which is where support already looks. A shop that quietly
    // stopped replicating has to be findable after the fact.
    void log(String event, String detail) =>
        audit.record('system', event, detail: detail);

    final eventLog = LanEventLog(db, deviceId: deviceId);
    final peers = LanPeerDirectory(log: log);
    final applier = LanApplier(
      deviceId: deviceId,
      orders: orders,
      tables: tables,
      settings: settings,
      log: eventLog,
      onRefused: log,
    );
    final credential = LanCredential(shopKey);
    final client = LanHttpClient(credential: credential);
    final fabric = LanFabric(
      deviceId: deviceId,
      log: eventLog,
      applier: applier,
      peers: peers,
      fetch: client.fetch,
      notify: (peer, events) => client.notify(peer, events, deviceId),
      onError: log,
    );
    return LanNode(
      deviceId: deviceId,
      deviceName: deviceName,
      log: eventLog,
      fabric: fabric,
      peers: peers,
      client: client,
      host: LanHost(
        protocol: LanProtocol(
          deviceId: deviceId,
          log: eventLog,
          applier: applier,
          credential: credential,
          onRefused: log,
        ),
        port: port,
        log: log,
        localAddresses: localAddresses,
      ),
      beacon: LanBeacon(
        deviceId: deviceId,
        name: deviceName,
        httpPort: port,
        port: beaconPort,
        onPeer: peers.seen,
        log: log,
        bind: beaconBind,
        localAddresses: localAddresses,
      ),
    );
  }

  final String deviceId;

  /// What the other devices in the shop call this one.
  final String deviceName;

  /// Who else is on the LAN, for the settings screen.
  final LanPeerDirectory peers;

  final LanEventLog _log;
  final LanFabric _fabric;
  final LanHost _host;
  final LanBeacon _beacon;
  final LanHttpClient _client;

  /// The start in flight, or the one that finished. Held so two callers cannot each
  /// bind the same port: the app shell starts the node, and the LAN switch can ask
  /// for it again in the same second.
  Future<void>? _starting;

  /// Handed to the stores so a committed change is announced from inside their own
  /// write transaction.
  void publish(LanEventKind kind, String recordUuid, Map<String, dynamic> payload) =>
      _fabric.publish(kind, recordUuid, payload);

  /// The address and port this device is answering on, or null when it never got a
  /// socket. Shown on the settings screen, because "the fabric is on" and "the
  /// fabric is reachable" are different facts and support needs both.
  String? get servingAt =>
      _host.isServing ? '${_host.host}:${_host.boundPort}' : null;

  DateTime? get lastPassAt => _fabric.lastPassAt;
  String? get lastError => _fabric.lastError;

  /// How far this device has read each peer, so a stuck cursor is visible.
  Map<String, int> get cursors => _log.cursors();

  /// This device's whole LAN state as the settings screen shows it.
  LanFacts get facts => (
        servingAt: servingAt,
        peers: peers.all,
        refused: peers.refused,
        cursors: cursors,
        lastPassAt: lastPassAt,
        lastError: lastError,
      );

  /// Whether this device is on the LAN right now.
  bool get isRunning => _host.isServing || _beacon.isRunning;

  /// Bind, announce, and start catching up. Never throws: a fabric that cannot
  /// start leaves a till that sells exactly as it did before.
  ///
  /// Idempotent, including while the first start is still awaiting its socket.
  /// Two binds on one port is a till that serves its peers from whichever half
  /// won, so asking twice has to be free.
  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    await _host.start();
    await _beacon.start();
    _fabric.start();
  }

  /// Come off the LAN: the socket closes and the announcements stop with the
  /// switch rather than at the next restart.
  ///
  /// Reversible, which is why the HTTP client is left alone here. A closed client
  /// cannot be reopened, and a device switched off and on again has to be able to
  /// reach its peers; letting it go is [dispose]'s job.
  Future<void> stop() async {
    _starting = null;
    _fabric.stop();
    await _beacon.stop();
    await _host.stop();
  }

  /// Come off the LAN for good, when the app itself is going away.
  Future<void> dispose() async {
    await stop();
    _client.close();
  }

  /// One catch-up pass now, for the Sync now button on the settings screen.
  Future<void> pass() => _fabric.pass();
}
