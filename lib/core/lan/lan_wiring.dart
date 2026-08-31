import 'dart:async';
import 'dart:io';

import '../../domain/order.dart';
import '../audit/audit_log.dart';
import '../db/database.dart';
import '../db/order_store.dart';
import '../db/reservation_store.dart';
import '../db/settings_store.dart';
import '../db/table_assignment_store.dart';
import '../db/table_store.dart';
import 'lan_applier.dart';
import 'lan_beacon.dart';
import 'lan_claim.dart';
import 'lan_event.dart';
import 'lan_credential.dart';
import 'lan_event_log.dart';
import 'lan_fabric.dart';
import 'lan_peer.dart';
import 'lan_shift_board.dart';
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
    required LanClaimDesk claims,
    required this.peers,
  })  : _log = log,
        _fabric = fabric,
        _host = host,
        _beacon = beacon,
        _client = client,
        _claims = claims;

  /// Builds every part and joins them up. Nothing binds or announces until
  /// [start] is called.
  factory LanNode.build({
    required Db db,
    required String deviceId,
    required String deviceName,
    /// The shop's shared key, read at the moment of the ask like the takeover
    /// switch below, so a manager who rotates the key has rotated it for the
    /// request that arrives a second later instead of at the next restart.
    /// Required rather than optional so a fabric can never be assembled without a
    /// key: an unauthenticated till would serve the shop's tabs to any device on
    /// the subnet.
    required String Function() shopKey,
    required OrderStore orders,
    required TableStore tables,
    required SettingsStore settings,
    required ReservationStore reservations,
    required TableAssignmentStore assignments,
    required AuditLog audit,
    required int port,
    required int beaconPort,
    // The seams LanHost and LanBeacon already take, passed through so a suite can
    // prove this assembly binds, lets go and binds again without touching a real
    // shop network. Null everywhere on a till, which is the whole point.
    Future<List<String>> Function()? localAddresses,
    Future<RawDatagramSocket> Function(InternetAddress address, int port)?
        beaconBind,
    /// The same kind of seam: a suite can stand two assembled tills next to each
    /// other and prove a tab really changes hands, without a shop network. Null on
    /// a till, which is the whole point.
    LanHttpClient? client,
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
      reservations: reservations,
      assignments: assignments,
      log: eventLog,
      onRefused: log,
    );
    final credential = LanCredential.rotating(shopKey);
    final http = client ?? LanHttpClient(credential: credential);
    final claims = LanClaimDesk(
      deviceId: deviceId,
      orders: orders,
      // Read at the moment of the ask, so a manager who switches takeovers off has
      // switched them off for the request that arrives a second later.
      allowed: () => settings.lanAllowTakeover,
      audit: log,
    );
    final fabric = LanFabric(
      deviceId: deviceId,
      log: eventLog,
      applier: applier,
      peers: peers,
      fetch: http.fetch,
      notify: (peer, events) => http.notify(peer, events, deviceId),
      onError: log,
    );
    return LanNode(
      deviceId: deviceId,
      deviceName: deviceName,
      log: eventLog,
      fabric: fabric,
      peers: peers,
      client: http,
      claims: claims,
      host: LanHost(
        protocol: LanProtocol(
          deviceId: deviceId,
          log: eventLog,
          applier: applier,
          credential: credential,
          claims: claims,
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
  final LanClaimDesk _claims;

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

  /// Tell the shop this till has closed its trading day.
  ///
  /// Advisory and one-way: nothing waits for an answer, nothing is retried beyond
  /// the ordinary catch-up, and a device that hears it decides for itself what to
  /// do. Called after the drawer is counted and the shift is already closed, so a
  /// fabric that is not there costs a log line and nothing else.
  /// Keyed on the device rather than on the shift, because what the other tills act
  /// on is "that till is done for today", one fact per device: a second close
  /// replaces the first instead of leaving two notices to disagree.
  String get dayCloseRecord => 'day-close-$deviceId';

  void announceDayClose({
    required String businessDate,
    String? cashierId,
  }) =>
      publish(
        LanEventKind.shiftLifecycle,
        dayCloseRecord,
        LanShiftNotice(
          deviceId: deviceId,
          deviceName: deviceName,
          businessDate: businessDate,
          at: DateTime.now().toUtc(),
          cashierId: cashierId,
        ).toMap(),
      );

  /// Take a tab another till has parked, with that till's agreement.
  ///
  /// The owner has to answer: it is the one that gives the tab up, and it does so
  /// in the same breath as agreeing, so there is never an instant where two tills
  /// could each settle it. An owner that is off, asleep or on the wrong side of a
  /// dead switch is therefore a refusal and not a delay, because the alternative is
  /// a bill paid twice.
  ///
  /// Never on a selling path: this is a deliberate action behind a manager gate,
  /// and the till it runs on is not mid-sale.
  Future<LanClaimResult> claim(Order order, {String? cashier}) async {
    final owner = _peerFor(order.deviceId);
    if (owner == null) {
      return (
        order: null,
        refusal: LanClaimRefusal.ownerUnreachable,
        detail: order.deviceId,
      );
    }
    try {
      final payload = await _client.claim(owner,
          orderUuid: order.uuid, deviceId: deviceId, cashier: cashier);
      final taken = _claims.accept(payload, cashier: cashier);
      if (taken == null) {
        return (
          order: null,
          refusal: LanClaimRefusal.refused,
          detail: 'the answer was not this tab',
        );
      }
      return (order: taken, refusal: null, detail: null);
    } on LanTabRefused catch (e) {
      return (order: null, refusal: LanClaimRefusal.refused, detail: e.reason);
    } catch (e) {
      // Anything that is not an answer is an unreachable till, which is the case
      // where the tab has to stay exactly where it is: the owner could not let go
      // of it, so nobody else may pick it up.
      return (
        order: null,
        refusal: LanClaimRefusal.ownerUnreachable,
        detail: '$e',
      );
    }
  }

  /// The peer that owns [deviceId], or null when this device has not seen it
  /// recently enough to ask it anything.
  LanPeer? _peerFor(String ownerDeviceId) {
    for (final peer in peers.active) {
      if (peer.deviceId == ownerDeviceId) return peer;
    }
    return null;
  }
}
