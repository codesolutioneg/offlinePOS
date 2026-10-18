import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import '../../domain/order.dart';
import '../audit/audit_log.dart';
import '../auth/bootstrap_cashier.dart';
import '../auth/fingerprint_store.dart';
import '../auth/user_store.dart';
import '../db/attendance_store.dart';
import '../db/catalogue_store.dart';
import '../db/data_reset.dart';
import '../db/database.dart';
import '../db/order_store.dart';
import '../db/reservation_store.dart';
import '../db/settings_store.dart';
import '../db/shift_store.dart';
import '../db/sqlite_outbox_store.dart';
import '../db/stress_purge.dart';
import '../db/table_assignment_store.dart';
import '../db/table_store.dart';
import '../printing/printer_registry.dart';
import '../sync/odoo_endpoint.dart';
import '../sync/stress_firebase_purge.dart';
import '../updates/app_build.dart';
import '../updates/download.dart';
import '../../domain/table_section_config.dart';
import 'lan_applier.dart';
import 'lan_beacon.dart';
import 'lan_tally.dart';
import 'lan_claim.dart';
import 'lan_event.dart';
import 'lan_credential.dart';
import 'lan_event_log.dart';
import 'lan_fabric.dart';
import 'lan_number_desk.dart';
import 'lan_peer.dart';
import 'lan_seat_desk.dart';
import 'lan_shift_board.dart';
import 'lan_traffic.dart';
import 'lan_transport.dart';
import 'lan_update.dart';

/// Everything the shop network screen reports about this device.
///
/// Read on every rebuild rather than handed over once, because all of it changes
/// while somebody is looking at it: the beacon finds a device, a pull fails, a
/// cursor moves. A peer list frozen when the screen opened is a support screen that
/// lies, which is worse than no screen at all.
typedef LanFacts = ({
  String? servingAt,
  String? hostError,
  List<LanPeer> peers,
  List<LanPeer> refused,
  Map<String, int> cursors,
  DateTime? lastPassAt,
  String? lastError,
});

/// Read every till heard from since [since] to the end of its log, and answer the
/// ones that could not be. A till last heard from before [since] is not asked: it
/// was not part of this shift.
Future<List<LanTillGap>> _catchUpPeers(
  LanFabric fabric,
  LanPeerDirectory peers,
  DateTime since, {
  void Function(String status)? onProgress,
}) async {
  final targets =
      peers.all.where((p) => !p.lastSeenAt.isBefore(since.toUtc())).toList();
  final failed = await fabric.catchUp(targets, onProgress: onProgress);
  return [
    for (final p in targets)
      if (failed[p.deviceId] case final reason?)
        LanTillGap(
          deviceId: p.deviceId,
          name: p.name,
          reason: reason,
          lastSeenAt: p.lastSeenAt,
        ),
  ];
}

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
    required LanSeatDesk seats,
    required this.peers,
    LanTraffic? traffic,
    /// The primary answers table reservations and order numbers; everyone else
    /// asks it.
    required bool Function() isPrimary,
    required bool Function() isSecondary,
    required String? Function() primaryDeviceId,
    required LanLog report,
    /// The paid sales this till holds in a window, any device, for the tally a
    /// close runs against the other tills.
    required List<String> Function(DateTime since, DateTime until) saleUuids,
    this.hostRetry = const Duration(seconds: 30),
  })  : traffic = traffic ?? LanTraffic(),
        _log = log,
        _saleUuids = saleUuids,
        _isSecondary = isSecondary,
        _report = report,
        _fabric = fabric,
        _host = host,
        _beacon = beacon,
        _client = client,
        _claims = claims,
        _seats = seats,
        _isPrimary = isPrimary,
        _primaryDeviceId = primaryDeviceId;

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
    required UserStore users,
    required PrinterRegistry printers,
    required OdooEndpointStore endpoints,
    AttendanceStore? attendance,
    FingerprintStore? fingerprints,
    CatalogueStore? catalogue,
    ShiftStore? shifts,
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
    Future<HttpServer> Function(InternetAddress address, int port)? hostBind,
    /// The same kind of seam: a suite can stand two assembled tills next to each
    /// other and prove a tab really changes hands, without a shop network. Null on
    /// a till, which is the whole point.
    LanHttpClient? client,
    /// After a peer shop bundle lands (Dishflow mirror, …), re-wire senders.
    void Function()? onShopBundleApplied,
    Duration hostRetry = const Duration(seconds: 30),
    /// This build, offered to the other tills while this one is the primary. Null
    /// on a developer's copy, which has no release build to give.
    LanUpdateOffer? updateOffer,
  }) {
    // Every fabric refusal, dead peer and failed announce lands in the audit trail
    // under 'system', which is where support already looks. A shop that quietly
    // stopped replicating has to be findable after the fact.
    void log(String event, String detail) =>
        audit.record('system', event, detail: detail);

    final eventLog = LanEventLog(db, deviceId: deviceId);
    final peers = LanPeerDirectory(log: log);
    final traffic =
        LanTraffic(clockOffsetOf: (id) => peers.byId(id)?.clockOffset);
    final applier = LanApplier(
      deviceId: deviceId,
      orders: orders,
      tables: tables,
      settings: settings,
      reservations: reservations,
      assignments: assignments,
      attendance: attendance,
      fingerprints: fingerprints,
      shifts: shifts,
      users: users,
      log: eventLog,
      onShopBundleApplied: onShopBundleApplied,
      onStressCleanup: () => unawaited(StressFirebasePurge().purgeEverywhere(db)),
      onHistoryWipe: (before) {
        final wiped = wipeOrderHistory(db, before: before);
        settings.historyWipedAt = before;
        settings.resetOrderNumbers();
        log('orders.history.wiped',
            'from another till, before ${before.toIso8601String()}: '
            '${wiped.orders} orders, ${wiped.shifts} shifts');
      },
      // A peer booked this ticket into Odoo (full-session resend). Drop our copy
      // of the push so Sync now cannot open a second sale order for it.
      onOrderSyncedFromPeer: (uuid) =>
          SqliteOutboxStore(db).forgetOrderPush(uuid),
      onRefused: log,
    );
    final credential = LanCredential.rotating(shopKey);
    final http = client ??
        LanHttpClient(credential: credential, selfId: deviceId, selfPort: port);
    final claims = LanClaimDesk(
      deviceId: deviceId,
      orders: orders,
      // Shop-wide switch, or the waiter who opened the tab / a manager.
      mayGrant: ({required order, requesterId, asManager = false}) =>
          settings.lanAllowTakeover ||
          asManager ||
          (requesterId != null && requesterId == order.cashierId),
      audit: log,
    );
    final seats = LanSeatDesk(orders: orders);
    final numbers =
        LanNumberDesk(deviceId: deviceId, settings: settings, orders: orders);
    final fabric = LanFabric(
      deviceId: deviceId,
      log: eventLog,
      applier: applier,
      peers: peers,
      fetch: http.fetch,
      notify: (peer, events) => http.notify(peer, events, deviceId),
      onError: log,
      traffic: traffic,
    );
    Map<String, dynamic>? joinGate({
      required String pin,
      required String peerDeviceId,
    }) {
      if (!settings.isLanPrimary) return null;
      if (!settings.consumeJoinPin(pin)) return null;
      final key = settings.lanShopKey;
      if (key == null || key.isEmpty) return null;
      log('lan.device.joined', peerDeviceId);
      return {
        'shop_key': key,
        'section_configs': {
          for (final e in settings.allSectionConfigs().entries)
            e.key: e.value.toMap(),
        },
        'shop_bundle': settings.exportShopBundle(),
        // Real roster only — Setup is a local bootstrap account, never shared.
        'users': [
          for (final u in users.all())
            if (u.id != BootstrapCashier.id) u.toMap(),
        ],
        // Same shop LAN → same ESC/POS hosts (receipt / kitchen / stations).
        'printers': printers.toMap(),
        // Endpoint so the secondary can refresh later; catalogue so it can sell
        // immediately even offline / before the first Odoo pull finishes.
        'odoo_endpoint': endpoints.load()?.toMap(),
        'attendance_open': attendance?.exportOpen() ?? const [],
        'fingerprints': fingerprints?.agentPayload() ?? const [],
        if (catalogue != null) 'catalogue': catalogue.exportLanSnapshot(),
        'tables': [for (final t in tables.all()) t.toMap()],
        // Full open floor — every till's held/seated tabs — so a rejoining
        // secondary matches the shop, not only what this primary owns.
        'open_orders': [
          for (final o in orders.occupyingAnywhere()) o.toMap(),
        ],
      };
    }

    final host = LanHost(
      protocol: LanProtocol(
        deviceId: deviceId,
        log: eventLog,
        applier: applier,
        credential: credential,
        claims: claims,
        seats: () => settings.isLanPrimary ? seats : null,
        numbers: () => settings.isLanPrimary ? numbers : null,
        catchUp: (since) async => [
          for (final gap in await _catchUpPeers(fabric, peers, since)) gap.toMap(),
        ],
        tally: orders.saleUuidsBetween,
        traffic: traffic,
        updates: () => settings.isLanPrimary ? updateOffer : null,
        onContact: (id, from, peerPort) =>
            peers.heard(id, host: from, port: peerPort),
        onJoin: joinGate,
        onRefused: log,
      ),
      port: port,
      log: log,
      bind: hostBind,
      localAddresses: localAddresses,
    );
    return LanNode(
      deviceId: deviceId,
      deviceName: deviceName,
      log: eventLog,
      fabric: fabric,
      peers: peers,
      traffic: traffic,
      client: http,
      claims: claims,
      seats: seats,
      isPrimary: () => settings.isLanPrimary,
      isSecondary: () => settings.deviceRole == DeviceRole.secondary,
      primaryDeviceId: () => settings.lanPrimaryDeviceId,
      report: log,
      saleUuids: orders.saleUuidsBetween,
      hostRetry: hostRetry,
      host: host,
      beacon: LanBeacon(
        deviceId: deviceId,
        name: deviceName,
        httpPort: port,
        port: beaconPort,
        onPeer: peers.seen,
        role: () => settings.deviceRole,
        serving: () => host.isServing,
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

  /// What passed to and from each of them since the app started, and how fast.
  final LanTraffic traffic;

  final LanEventLog _log;
  final LanFabric _fabric;
  final LanHost _host;
  final LanBeacon _beacon;
  final LanHttpClient _client;
  final LanClaimDesk _claims;
  final LanSeatDesk _seats;
  final bool Function() _isPrimary;
  final bool Function() _isSecondary;
  final String? Function() _primaryDeviceId;
  final LanLog _report;
  final List<String> Function(DateTime since, DateTime until) _saleUuids;

  /// The start in flight, or the one that finished. Held so two callers cannot each
  /// bind the same port: the app shell starts the node, and the LAN switch can ask
  /// for it again in the same second.
  Future<void>? _starting;

  /// How often a server that could not bind tries again. Without it a till that
  /// started before its network was up served nobody until the app restarted.
  final Duration hostRetry;
  Timer? _hostRetryTimer;

  /// Whether the shop primary is currently visible on the LAN.
  ///
  /// Prefers the device id recorded at join; falls back to any peer advertising
  /// [DeviceRole.primary] (newer builds). Empty peer list = primary not online.
  bool primaryIsReachable(SettingsStore settings) => primaryReached(
        activePeers: peers.active,
        primaryDeviceId: settings.lanPrimaryDeviceId,
      );

  /// Handed to the stores so a committed change is announced from inside their own
  /// write transaction.
  void publish(LanEventKind kind, String recordUuid, Map<String, dynamic> payload) =>
      _fabric.publish(kind, recordUuid, payload);

  /// The address and port this device is answering on, or null when it never got a
  /// socket. Shown on the settings screen, because "the fabric is on" and "the
  /// fabric is reachable" are different facts and support needs both.
  String? get servingAt =>
      _host.isServing ? '${_host.hosts.join(' / ')}:${_host.boundPort}' : null;

  /// Why the server could not bind, while it is retrying.
  String? get hostError => _host.isServing ? null : _host.lastError;

  DateTime? get lastPassAt => _fabric.lastPassAt;
  String? get lastError => _fabric.lastError;

  /// How far this device has read each peer, so a stuck cursor is visible.
  Map<String, int> get cursors => _log.cursors();

  /// This device's whole LAN state as the settings screen shows it.
  LanFacts get facts => (
        servingAt: servingAt,
        hostError: hostError,
        peers: peers.all,
        refused: peers.refused,
        cursors: cursors,
        lastPassAt: lastPassAt,
        lastError: lastError,
      );

  /// Whether this device is on the LAN right now. True with the beacon alone: a
  /// secondary whose own server is down can still ask the primary.
  bool get isRunning => _host.isServing || _beacon.isRunning;

  /// Whether the other devices can reach this one. Announced on the beacon, so a
  /// primary that cannot serve is not mistaken for one that is up.
  bool get isServing => _host.isServing;

  /// Bind, announce, and start catching up. Never throws: a fabric that cannot
  /// start leaves a till that sells exactly as it did before.
  ///
  /// Idempotent, including while the first start is still awaiting its socket.
  /// Two binds on one port is a till that serves its peers from whichever half
  /// won, so asking twice has to be free.
  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    if (!await _host.start()) _retryHost();
    await _beacon.start();
    _fabric.start();
    _warmUpNumbers();
  }

  void _retryHost() {
    _hostRetryTimer?.cancel();
    _hostRetryTimer = Timer.periodic(hostRetry, (timer) async {
      if (!await _host.start()) return;
      // Switched off while this bind was in flight: let the socket go again.
      if (!timer.isActive) return _host.stop();
      timer.cancel();
    });
  }

  /// Come off the LAN: the socket closes and the announcements stop with the
  /// switch rather than at the next restart.
  ///
  /// Reversible, which is why the HTTP client is left alone here. A closed client
  /// cannot be reopened, and a device switched off and on again has to be able to
  /// reach its peers; letting it go is [dispose]'s job.
  Future<void> stop() async {
    _starting = null;
    _hostRetryTimer?.cancel();
    _hostRetryTimer = null;
    _numberWarmUpTimer?.cancel();
    _numberWarmUpTimer = null;
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

  /// Read every peer's log again from the start, for a till that skipped an event
  /// it should have kept (a paid sale it still shows as open, or does not show).
  Future<void> rereadAll() {
    _log.resetCursors();
    _report('lan.cursors.reset', 'reading every till again from the start');
    return _fabric.pass();
  }

  /// Present a join PIN to [primary] and return shop_key + section_configs.
  Future<Map<String, dynamic>> joinWithPrimary(LanPeer primary, String pin) =>
      _client.join(primary, pin: pin, deviceId: deviceId);

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

  /// Shared record for shop-shift open so the latest open wins across tills.
  static const shopShiftRecord = 'shop-shift';

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
          action: LanShiftAction.close,
        ).toMap(),
      );

  /// Tell peers a shop shift opened here so they quiet-open a local drawer.
  void announceShiftOpen({
    required String businessDate,
    String? cashierId,
  }) =>
      publish(
        LanEventKind.shiftLifecycle,
        shopShiftRecord,
        LanShiftNotice(
          deviceId: deviceId,
          deviceName: deviceName,
          businessDate: businessDate,
          at: DateTime.now().toUtc(),
          cashierId: cashierId,
          action: LanShiftAction.open,
        ).toMap(),
      );

  /// Tell the other tills the Stress Lab was cleared here, so they drop their
  /// copies of its orders too.
  void announceStressCleanup() => publish(LanEventKind.stressCleanup,
      'stress-cleanup', {'note': kStressNote});

  /// Tell the other tills the order history was wiped here, so they wipe theirs
  /// from before the same moment.
  void announceHistoryWipe(DateTime before) => publish(LanEventKind.historyWipe,
      'history-wipe', {'before': before.toUtc().toIso8601String()});

  /// Make sure the shop's sales are all in one place before a shift closes, and
  /// name the tills that stopped that from being true.
  ///
  /// This till hands over what it has and reads what it is missing first. On a
  /// secondary, the primary is then asked to read every till seen since [since]
  /// to the end of its log, because the primary is where the shop's sales are
  /// meant to meet; a primary that cannot be asked is itself the gap. On the
  /// primary, or on a till with no primary at all, this till reads them itself.
  ///
  /// [until] closes the window the tills are compared over: the moment the
  /// session closed when one is being sent again, otherwise now. Without it a
  /// resend of last night would count this morning's sales on the other tills
  /// as gaps and never go out.
  ///
  /// [closing] marks [until] as the bound a shift is about to close at, which
  /// holds the tills' clocks to it as well (see [_tallyPeers]).
  Future<List<LanTillGap>> catchUpBeforeClose({
    required DateTime since,
    DateTime? until,
    bool closing = false,
    void Function(String status)? onProgress,
  }) async {
    final gaps = await _collectBeforeClose(since: since, onProgress: onProgress);
    // Reading the others is not the same as holding what they rang. Each till is
    // asked for its own list and anything it has that this one does not is a gap,
    // whether the read above failed, was cut short, or went through the primary.
    return [
      ...gaps,
      ...await _tallyPeers(
        since,
        until: until?.toUtc() ?? DateTime.now().toUtc(),
        closing: closing && until != null,
        skip: {for (final gap in gaps) gap.deviceId},
        onProgress: onProgress,
      ),
    ];
  }

  /// Each till's clock offset as its last tally answer measured it, for a till
  /// whose beacon does not reach this one and so carries none.
  final Map<String, Duration> _answeredOffsets = {};

  Duration? _offsetOf(LanPeer peer) =>
      peer.clockOffset ?? _answeredOffsets[peer.deviceId];

  /// The last bound [settleCloseCutoff] chose, and how far ahead of this
  /// till's clock it allowed a till to run.
  ({DateTime at, Duration cover})? _settled;

  /// Where a close since [since] can be bounded so the tills' clocks agree on
  /// it, after waiting until they have all passed it. See [closeCutoffFor].
  /// [onWait] is told when the wait ends; once [cancelled] completes the wait
  /// stops and null is returned.
  Future<DateTime?> settleCloseCutoff(DateTime since,
      {void Function(DateTime readyAt)? onWait, Future<void>? cancelled}) async {
    var stop = false;
    cancelled?.whenComplete(() => stop = true).ignore();
    final now = DateTime.now().toUtc();
    final targets = _tallyTargets(since, const {});
    if (targets.isEmpty) {
      _settled = (at: now, cover: kCloseClockMargin);
      return now;
    }
    final cutoff = closeCutoffFor(now, targets.map(_offsetOf));
    _settled = (at: cutoff.at, cover: cutoff.at.difference(now));
    onWait?.call(cutoff.askAfter);
    // A timer can fire a little early, so check the clock again after it.
    var wait = cutoff.askAfter.difference(DateTime.now().toUtc());
    while (wait > Duration.zero && !stop) {
      final woke = Completer<void>();
      void wake() {
        if (!woke.isCompleted) woke.complete();
      }
      final timer = Timer(wait, wake);
      cancelled?.whenComplete(wake).ignore();
      await woke.future;
      timer.cancel();
      wait = cutoff.askAfter.difference(DateTime.now().toUtc());
    }
    if (stop) {
      _settled = null;
      return null;
    }
    return cutoff.at;
  }

  List<LanPeer> _tallyTargets(DateTime since, Set<String> skip) => peers.all
      .where((p) =>
          p.deviceId != deviceId &&
          !skip.contains(p.deviceId) &&
          !p.lastSeenAt.isBefore(since.toUtc()))
      .toList();

  /// A sale a peer completes after [until] is outside this check; it goes to
  /// Odoo under the next close and the server books it once by its uuid.
  /// When [closing], [until] is where the shift closes, and a till is also named
  /// when its clock is too far out to wait for, or had not passed [until] when
  /// it answered: either way it could still ring a sale inside the window. So is
  /// a till found further ahead than the bound allowed for, whose sales rung
  /// before the close are stamped past it.
  Future<List<LanTillGap>> _tallyPeers(
    DateTime since, {
    required DateTime until,
    required Set<String> skip,
    bool closing = false,
    void Function(String status)? onProgress,
  }) async {
    final targets = _tallyTargets(since, skip);
    if (targets.isEmpty) return const [];
    final offClock = closing ? clockGaps(targets, _offsetOf) : <LanTillGap>[];
    final farOff = {for (final gap in offClock) gap.deviceId};
    final settled = _settled;
    final cover = settled != null && settled.at == until ? settled.cover : null;
    onProgress?.call('Checking every till handed over its sales...');
    final answers = <LanTallyAnswer>[];
    final short = <LanTillGap>[];
    for (final peer in targets) {
      try {
        final reply = await _client.tally(peer,
            deviceId: deviceId, since: since, until: until);
        if (reply.clockOffset case final offset?) {
          _answeredOffsets[peer.deviceId] = offset;
        }
        if (closing && !farOff.contains(peer.deviceId)) {
          if (clockShortGap(peer, reply.clock, until) case final gap?) {
            short.add(gap);
          } else if (cover != null) {
            if (clockAheadGap(peer, reply.clockOffset, cover,
                    spread: reply.clockSpread)
                case final gap?) {
              short.add(gap);
            }
          }
        }
        answers.add(LanTallyAnswer.counted(peer, reply.uuids.toSet()));
      } catch (e) {
        _report('lan.tally.failed', '${peer.deviceId} (${peer.name}): $e');
        answers.add(LanTallyAnswer.fromError(peer, e));
      }
    }
    // Read after the answers, so a sale that arrived while they were being
    // collected counts as held.
    return [
      ...offClock,
      ...short,
      ...tallyGaps(local: _saleUuids(since, until).toSet(), answers: answers),
    ];
  }

  Future<List<LanTillGap>> _collectBeforeClose({
    required DateTime since,
    void Function(String status)? onProgress,
  }) async {
    onProgress?.call('Handing over this till\'s sales...');
    await _fabric.pass();
    final primaryId = _primaryDeviceId()?.trim();
    final hasPrimary = (primaryId != null && primaryId.isNotEmpty) ||
        peers.all.any((p) => p.role == DeviceRole.primary);
    if (_isPrimary() || !_isSecondary() || !hasPrimary) {
      return _catchUpPeers(_fabric, peers, since, onProgress: onProgress);
    }
    final primary = _primaryPeer();
    if (primary == null) {
      final known = peers.all
          .where((p) => primaryId != null && primaryId.isNotEmpty
              ? p.deviceId == primaryId
              : p.role == DeviceRole.primary)
          .firstOrNull;
      return [
        LanTillGap(
          deviceId: known?.deviceId ?? primaryId ?? '',
          name: known?.name ?? 'Primary',
          reason: 'the primary is not on the network',
          lastSeenAt: known?.lastSeenAt,
        ),
      ];
    }
    final who = primary.name.isEmpty ? primary.deviceId : primary.name;
    onProgress?.call('Asking $who to collect every till...');
    try {
      return await _client.catchUp(primary, deviceId: deviceId, since: since);
    } catch (e) {
      _report('lan.catchup.failed', '${primary.deviceId} (${primary.name}): $e');
      return [
        LanTillGap(
          deviceId: primary.deviceId,
          name: primary.name,
          reason: '$e',
          lastSeenAt: primary.lastSeenAt,
        ),
      ];
    }
  }

  /// Take a tab another till has parked, with that till's agreement.
  ///
  /// The owner is asked, and asked again when it stays silent. Only after every
  /// retry, and only with [asManager], does this till seize its local replica and
  /// announce the claim so the silent peer drops ownership when it rejoins.
  /// Without a manager the answer is [LanClaimRefusal.needsManager].
  ///
  /// Never on a selling path: this is a deliberate action behind a confirmation,
  /// and the till it runs on is not mid-sale.
  Future<LanClaimResult> claim(
    Order order, {
    String? cashier,
    bool asManager = false,
  }) {
    final owner = _peerFor(order.deviceId);
    return _claims.take(
      order,
      ask: owner == null
          ? null
          : () => _client.claim(
                owner,
                orderUuid: order.uuid,
                deviceId: deviceId,
                cashier: cashier,
                asManager: asManager,
              ),
      cashier: cashier,
      asManager: asManager,
    );
  }

  /// Reserve [table] with the shop's primary before seating a new tab on it.
  ///
  /// The primary answers from its own replica and its recent grants, so two tills
  /// tapping one empty table inside the replication window cannot both seat it. A
  /// primary that cannot be asked answers [LanSeatAnswer.unasked] and the till
  /// seats anyway: selling does not stop because the switch did.
  Future<LanSeatAnswer> reserveTable(String table) async {
    if (_isPrimary()) return _seats.reserve(table, deviceId);
    final primary = _primaryPeer();
    if (primary == null) return LanSeatAnswer.unasked;
    try {
      return await _client.seat(primary, table: table, deviceId: deviceId);
    } catch (e) {
      _report('lan.seat.unasked', '$table: $e');
      return LanSeatAnswer.unasked;
    }
  }

  late final LanNumberSupply _numbers = LanNumberSupply(ask: _askNumbers);

  Future<List<String>> _askNumbers(int count) async {
    if (_isPrimary()) return const [];
    final primary = _primaryPeer();
    if (primary == null) return const [];
    try {
      return await _client.numbers(primary, deviceId: deviceId, count: count);
    } catch (e) {
      _report('lan.number.unasked', '$e');
      return const [];
    }
  }

  /// Reserve the next order number from the primary before the sale needs it.
  /// Called as an order starts being rung; free when one is already held.
  void prepareOrderNumber() {
    if (_isPrimary() || !isRunning) return;
    _numbers.prepare();
  }

  /// The number reserved from the primary, or null for the till to number
  /// locally: on the primary itself, or with nothing reserved. Asks for the next
  /// one straight away, so a queue of sales does not fall back to local numbers.
  String? takeOrderNumber() {
    if (_isPrimary()) return null;
    final n = _numbers.take();
    prepareOrderNumber();
    return n;
  }

  /// Reserve numbers now and settle once the primary has answered (or could not
  /// be asked), so a run that pays within milliseconds of starting has them.
  Future<void> readyToNumber() {
    prepareOrderNumber();
    return _numbers.settled;
  }

  /// How often a secondary that has not had numbers yet asks again. The first
  /// sale after start-up would otherwise come before the first reserve.
  static const Duration numberWarmUp = Duration(seconds: 10);
  Timer? _numberWarmUpTimer;

  void _warmUpNumbers() {
    _numberWarmUpTimer?.cancel();
    if (!_isSecondary()) return;
    prepareOrderNumber();
    _numberWarmUpTimer = Timer.periodic(numberWarmUp, (timer) {
      if (_numbers.everFilled) return timer.cancel();
      prepareOrderNumber();
    });
  }

  /// Whether the shared counter belongs to another till. Such a till must not
  /// number from its own copy of it when nothing is reserved: the primary is
  /// handing those same numbers out.
  bool get numbersBelongToPrimary => _isSecondary();

  /// A build newer than [ownVersion] that the primary is offering and has signed
  /// with the shop key, or null when there is none (yet).
  ///
  /// The first ask starts the primary packing, which it answers "not ready", so
  /// null now can be an offer a minute later.
  Future<LanUpdateAvailable?> primaryUpdate(String ownVersion) async {
    if (_isPrimary()) return null;
    final own = AppBuild.tryParse(ownVersion);
    final primary = _primaryPeer();
    if (own == null || primary == null) return null;
    final Map<String, dynamic> manifest;
    try {
      manifest = await _client.updateManifest(primary, deviceId: deviceId);
    } catch (_) {
      // An older primary, or none offering: nothing to install.
      return null;
    }
    final offered = AppBuild.tryParse(manifest['version'] as String?);
    if (offered == null || !offered.isNewerThan(own)) return null;
    if (manifest['ready'] != true) return null;
    if (!_client.offerIsGenuine(manifest)) {
      _report('lan.update.refused',
          '${primary.deviceId} offered $offered without a valid shop-key signature');
      return null;
    }
    return LanUpdateAvailable(
      version: '$offered',
      size: manifest['size'] as int,
      sha256: manifest['sha256'] as String,
    );
  }

  /// Downloads [offer] into [staging] and checks it is byte for byte what the
  /// primary signed. Throws on anything short of that, leaving nothing behind.
  Future<File> downloadPrimaryUpdate(
      LanUpdateAvailable offer, Directory staging,
      {DownloadProgress? onProgress}) async {
    final primary = _primaryPeer();
    if (primary == null) throw StateError('the primary is not on the network');
    await staging.create(recursive: true);
    final sep = Platform.pathSeparator;
    final file = File('${staging.path}${sep}lan-${offer.version}.zip');
    final partial = File('${file.path}.download');
    try {
      await _client.downloadUpdate(primary,
          deviceId: deviceId,
          to: partial,
          onProgress: (got, total) => onProgress?.call(got, total ?? offer.size));
      final size = await partial.length();
      final digest = (await crypto.sha256.bind(partial.openRead()).first).toString();
      if (size != offer.size || digest != offer.sha256) {
        throw StateError('the download does not match what the primary signed '
            '($size bytes, $digest)');
      }
      if (await file.exists()) await file.delete();
      await partial.rename(file.path);
      return file;
    } catch (e) {
      _report('lan.update.download_failed', '$e');
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
  }

  LanPeer? _primaryPeer() {
    final id = _primaryDeviceId()?.trim();
    for (final peer in peers.active) {
      if (!peer.serving) continue;
      if (id != null && id.isNotEmpty ? peer.deviceId == id : peer.role == DeviceRole.primary) {
        return peer;
      }
    }
    return null;
  }

  /// Which tab is open on this till's screen, so it is never handed away while
  /// being rung up. Set by the app shell once it has a session.
  set tabOnScreen(bool Function(String orderUuid)? check) =>
      _claims.isOnScreen = check;

  /// The peer that owns [deviceId], or null when this device has not seen it
  /// recently enough to ask it anything.
  LanPeer? _peerFor(String ownerDeviceId) {
    for (final peer in peers.active) {
      if (peer.deviceId == ownerDeviceId) return peer;
    }
    return null;
  }
}
