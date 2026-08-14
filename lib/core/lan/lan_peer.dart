import '../db/schema.dart';

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

  bool get isCompatible => schemaVersion == Schema.version;

  Uri get baseUrl => Uri.parse('http://$host:$port');

  LanPeer seenAt(DateTime at, {String? host}) => LanPeer(
        deviceId: deviceId,
        name: name,
        host: host ?? this.host,
        port: port,
        schemaVersion: schemaVersion,
        lastSeenAt: at,
      );

  /// The beacon datagram. Deliberately tiny and free of anything private: it is
  /// broadcast to the whole subnet, so it carries an identity and a port and
  /// nothing a customer or a sale could be read out of.
  Map<String, dynamic> toMap() => {
        'device_id': deviceId,
        'name': name,
        'port': port,
        'schema': schemaVersion,
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
    return LanPeer(
      deviceId: deviceId,
      name: m['name'] is String ? m['name'] as String : deviceId,
      host: host,
      port: port,
      schemaVersion: schema,
      lastSeenAt: at,
    );
  }
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

  /// Peers turned away on a schema mismatch, shown on the settings screen so an
  /// unfinished rollout is visible on the device rather than only in the log.
  List<LanPeer> get refused =>
      _refused.values.toList()..sort((a, b) => a.name.compareTo(b.name));
}
