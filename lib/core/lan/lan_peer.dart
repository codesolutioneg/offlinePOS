import '../db/schema.dart';
import '../../domain/table_section_config.dart';

/// Where a fabric error or refusal is recorded. Wired to the audit log on a real
/// till, so a peer that never joined is answerable to support instead of being a
/// silence somebody has to guess at.
typedef LanLog = void Function(String event, String detail);

/// Another till (or a kitchen screen) that announced itself on the shop LAN.
class LanPeer {
  const LanPeer({
    required this.deviceId,
    required this.name,
    required this.host,
    required this.port,
    required this.schemaVersion,
    required this.lastSeenAt,
    this.role,
    this.serving = true,
    this.clockOffset,
  });

  /// The peer's own device id, which is its identity here. The address is not: a
  /// mesh-wifi shop moves DHCP leases around, so a peer that comes back on a new
  /// address is the same peer and must not be replayed from the start of its log.
  final String deviceId;

  /// What the device calls itself on the settings screen ("Front till", "Kitchen").
  final String name;

  final String host;
  final int port;

  /// The database version the peer is running. Events are only exchanged between
  /// tills on the same version: an event written by a newer build can describe a
  /// record this one has nowhere to put.
  final int schemaVersion;

  final DateTime lastSeenAt;

  /// Primary / secondary when the peer's build announces it; null on older beacons.
  final DeviceRole? role;

  /// False when the peer announced that its server could not bind: it is on the
  /// network, but every request to it would be refused.
  final bool serving;

  /// How far the peer's clock is ahead of this one (negative: behind), from the
  /// time its last beacon said it was sent. Null on beacons from older builds.
  ///
  /// Worth showing because the clocks matter twice: past
  /// `LanCredential.clockTolerance` the two refuse each other outright, and below
  /// it the newer of two edits to one tab is decided by whichever clock wrote it.
  final Duration? clockOffset;

  bool get isCompatible => schemaVersion == Schema.version;

  Uri get baseUrl => Uri.parse('http://$host:$port');

  LanPeer seenAt(DateTime at, {String? host}) => LanPeer(
        deviceId: deviceId,
        name: name,
        host: host ?? this.host,
        port: port,
        schemaVersion: schemaVersion,
        lastSeenAt: at,
        role: role,
        serving: serving,
        clockOffset: clockOffset,
      );

  /// The beacon datagram. Deliberately tiny and free of anything private: it is
  /// broadcast to the whole subnet, so it carries an identity and a port and
  /// nothing a customer or a sale could be read out of.
  Map<String, dynamic> toMap() => {
        'device_id': deviceId,
        'name': name,
        'port': port,
        'schema': schemaVersion,
        if (role != null && role != DeviceRole.unset) 'role': role!.wire,
        if (!serving) 'serving': false,
      };

  /// Throws [FormatException] on a datagram this build cannot read. Anything at all
  /// can send a packet to a broadcast port, so nothing here is trusted.
  factory LanPeer.fromMap(
    Map<String, dynamic> m, {
    required String host,
    required DateTime at,
  }) {
    final deviceId = m['device_id'];
    final port = m['port'];
    final schema = m['schema'];
    if (deviceId is! String || deviceId.isEmpty || port is! int || schema is! int) {
      throw const FormatException('beacon is missing device_id, port or schema');
    }
    DeviceRole? role;
    final rawRole = m['role'];
    if (rawRole is String && rawRole.isNotEmpty) {
      final parsed = DeviceRole.fromWire(rawRole);
      if (parsed != DeviceRole.unset) role = parsed;
    }
    final sentAt = m['sent_at'];
    return LanPeer(
      deviceId: deviceId,
      name: m['name'] is String ? m['name'] as String : deviceId,
      host: host,
      port: port,
      schemaVersion: schema,
      lastSeenAt: at,
      role: role,
      serving: m['serving'] != false,
      clockOffset: sentAt is int
          ? Duration(milliseconds: sentAt - at.toUtc().millisecondsSinceEpoch)
          : null,
    );
  }
}

/// A till that could not be read to the end of its log before a shift closed, so
/// the sales it holds may be missing from the device that asked.
class LanTillGap {
  const LanTillGap({
    required this.deviceId,
    required this.name,
    required this.reason,
    this.lastSeenAt,
  });

  final String deviceId;
  final String name;
  final String reason;
  final DateTime? lastSeenAt;

  Map<String, dynamic> toMap() => {
        'device_id': deviceId,
        'name': name,
        'reason': reason,
        if (lastSeenAt != null) 'last_seen_at': lastSeenAt!.toUtc().toIso8601String(),
      };

  factory LanTillGap.fromMap(Map<String, dynamic> m) => LanTillGap(
        deviceId: '${m['device_id'] ?? ''}',
        name: '${m['name'] ?? m['device_id'] ?? ''}',
        reason: '${m['reason'] ?? ''}',
        lastSeenAt: DateTime.tryParse('${m['last_seen_at']}')?.toUtc(),
      );
}

/// Whether the shop primary is among [activePeers].
///
/// Prefers [primaryDeviceId] from a prior join; otherwise any peer advertising
/// [DeviceRole.primary]. A primary announcing that it cannot serve is not reached.
bool primaryReached({
  required Iterable<LanPeer> activePeers,
  required String? primaryDeviceId,
}) {
  final id = primaryDeviceId?.trim();
  final serving = activePeers.where((p) => p.serving);
  if (id != null && id.isNotEmpty) {
    return serving.any((p) => p.deviceId == id);
  }
  return serving.any((p) => p.role == DeviceRole.primary);
}

/// Who is on the LAN right now, and who was refused.
///
/// Membership is soft on purpose: a peer that stops announcing goes stale and its
/// events stop being pulled, but nothing about selling changes when the list is
/// empty. A one-till shop and a shop whose switch died behave identically here.
class LanPeerDirectory {
  LanPeerDirectory({
    DateTime Function()? now,
    this.staleAfter = const Duration(minutes: 2),
    LanLog? log,
  })  : _now = now ?? DateTime.now,
        _log = log;

  final DateTime Function() _now;
  final LanLog? _log;

  /// How long after its last beacon a peer is no longer counted as present. A few
  /// missed announcements is a busy access point, not a device that left.
  final Duration staleAfter;

  final Map<String, LanPeer> _peers = {};
  final Map<String, LanPeer> _refused = {};

  /// Record a beacon. Returns the peer when it may be exchanged with, and null when
  /// it was refused, so the caller cannot accidentally treat a refusal as a join.
  ///
  /// A peer on another schema version is refused rather than tolerated. Applying
  /// its events would mean writing a record shaped for a database this till does
  /// not have, and a half-understood order is worse than a missing one.
  LanPeer? seen(LanPeer peer) {
    if (!peer.isCompatible) {
      final known = _refused[peer.deviceId];
      _refused[peer.deviceId] = peer;
      // Logged once per peer per run: a refused till announces every few seconds,
      // and the audit trail is not the place for a heartbeat.
      if (known == null) {
        _log?.call(
          'lan.peer.refused',
          '${peer.deviceId} (${peer.name}) at ${peer.host} runs schema '
              '${peer.schemaVersion}, this till runs ${Schema.version}',
        );
      }
      return null;
    }
    _refused.remove(peer.deviceId);
    final joined = peer.seenAt(_now().toUtc());
    final known = _peers[peer.deviceId];
    _peers[peer.deviceId] = joined;
    if (known == null) {
      _log?.call('lan.peer.joined',
          '${peer.deviceId} (${peer.name}) at ${peer.host}:${peer.port}');
    }
    return joined;
  }

  /// A signed request from [deviceId], which proves it is on the network and holds
  /// the shop key even when its beacon never arrives here (a second adapter, an
  /// access point that drops broadcast from one side). Without this a till that can
  /// hear the others but not be heard pushes to them and is never read from.
  ///
  /// A peer already known keeps what its beacon said and is only marked as seen.
  void heard(String deviceId, {required String host, required int port}) {
    if (deviceId.isEmpty || _refused.containsKey(deviceId)) return;
    final at = _now().toUtc();
    final known = _peers[deviceId];
    if (known != null) {
      _peers[deviceId] = known.seenAt(at);
      return;
    }
    _peers[deviceId] = LanPeer(
      deviceId: deviceId,
      name: deviceId,
      host: host,
      port: port,
      schemaVersion: Schema.version,
      lastSeenAt: at,
    );
    _log?.call('lan.peer.joined',
        '$deviceId at $host:$port, from its requests: its beacon does not reach this till');
  }

  /// Peers heard from recently enough to be worth talking to, by name.
  List<LanPeer> get active {
    final cutoff = _now().toUtc().subtract(staleAfter);
    return _peers.values.where((p) => p.lastSeenAt.isAfter(cutoff)).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  /// Everything heard from, stale included, for the LAN settings screen. Support
  /// needs to see "last seen 40 minutes ago" rather than an empty list.
  List<LanPeer> get all =>
      _peers.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  /// The peer last heard as [deviceId], stale or not.
  LanPeer? byId(String deviceId) => _peers[deviceId];

  /// Peers turned away on a schema mismatch, shown on the settings screen so an
  /// unfinished rollout is visible on the device rather than only in the log.
  List<LanPeer> get refused =>
      _refused.values.toList()..sort((a, b) => a.name.compareTo(b.name));
}
