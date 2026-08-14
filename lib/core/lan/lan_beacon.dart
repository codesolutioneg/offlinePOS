import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../db/schema.dart';
import 'lan_peer.dart';
import 'lan_transport.dart';

/// Announces this device on the shop LAN and listens for the others, over UDP
/// broadcast on a fixed port.
///
/// Broadcast rather than mDNS or a configured list of addresses: a shop plugs in a
/// second till without anyone typing an address, and DHCP leases move, so anything
/// written down at installation goes stale. The datagram carries an identity, a
/// port and a schema version, and nothing else: it goes to every device on the
/// subnet, so nothing about a sale or a customer belongs in it.
///
/// Discovery is never required for a sale. A beacon that never binds, a switch that
/// drops every packet and an empty peer list are all the same to a cashier.
class LanBeacon {
  LanBeacon({
    required this.deviceId,
    required this.name,
    required this.httpPort,
    required this.onPeer,
    this.port = 45334,
    this.interval = const Duration(seconds: 10),
    LanLog? log,
    Future<RawDatagramSocket> Function(InternetAddress address, int port)? bind,
    Future<List<String>> Function()? localAddresses,
  })  : _log = log,
        _bind = bind ?? RawDatagramSocket.bind,
        _localAddresses = localAddresses ?? lanAddresses;

  final String deviceId;

  /// What this device calls itself to the others. Shown on their settings screens,
  /// so it is the name a manager can act on rather than a uuid.
  final String name;

  /// The port this device serves the fabric on, which is the whole point of the
  /// announcement: a peer cannot pull from an address it has no port for.
  final int httpPort;

  /// The fixed broadcast port. Both ends have to agree on it without being told,
  /// which is exactly what a constant is for.
  final int port;

  /// How often the announcement repeats. Often enough that a till switched on
  /// mid-service is picked up within a few seconds, rarely enough to be invisible
  /// on the network.
  final Duration interval;

  /// Called for every peer heard from. Wired to the peer directory, which is what
  /// decides whether the peer is compatible.
  final void Function(LanPeer peer) onPeer;

  final LanLog? _log;
  final Future<RawDatagramSocket> Function(InternetAddress address, int port) _bind;
  final Future<List<String>> Function() _localAddresses;

  RawDatagramSocket? _socket;
  Timer? _timer;
  List<InternetAddress> _targets = const [];

  bool get isRunning => _socket != null;

  /// Binds, announces once immediately so a new device is seen without waiting a
  /// full interval, then keeps announcing.
  ///
  /// Never throws. A port in use or an interface that disappeared is logged and the
  /// till carries on with no fabric.
  Future<bool> start() async {
    if (_socket != null) return true;
    try {
      // Bound to every interface, unlike the HTTP server: a broadcast datagram is
      // not addressed to this device, so a socket bound to the LAN address alone
      // would never be handed one. reuse lets a second app on the same box (a till
      // and a kitchen screen during setup) listen at the same time.
      final socket = await _bind(InternetAddress.anyIPv4, port);
      socket.broadcastEnabled = true;
      _socket = socket;
      _targets = await _broadcastTargets();
      socket.listen(
        (event) {
          if (event == RawSocketEvent.read) _receive(socket);
        },
        onError: (Object e) => _log?.call('lan.beacon.error', '$e'),
      );
      announce();
      _timer = Timer.periodic(interval, (_) => announce());
      return true;
    } catch (e) {
      _log?.call('lan.beacon.unavailable', 'cannot listen on $port: $e');
      return false;
    }
  }

  /// Say who and where this device is. Silent when there is nothing to send to.
  void announce() {
    final socket = _socket;
    if (socket == null) return;
    final datagram = utf8.encode(jsonEncode({
      'device_id': deviceId,
      'name': name,
      'port': httpPort,
      'schema': Schema.version,
    }));
    for (final target in _targets) {
      try {
        socket.send(datagram, target, port);
      } catch (e) {
        // A subnet that cannot be broadcast to is not worth a retry loop; the next
        // interval tries again anyway.
        _log?.call('lan.beacon.error', 'announce to ${target.address}: $e');
      }
    }
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _socket?.close();
    _socket = null;
  }

  void _receive(RawDatagramSocket socket) {
    final datagram = socket.receive();
    if (datagram == null) return;
    try {
      final decoded =
          (jsonDecode(utf8.decode(datagram.data)) as Map).cast<String, dynamic>();
      final peer = LanPeer.fromMap(
        decoded,
        host: datagram.address.address,
        at: DateTime.now().toUtc(),
      );
      // Our own announcement, arriving back off the broadcast.
      if (peer.deviceId == deviceId) return;
      onPeer(peer);
    } catch (_) {
      // Anything at all can send a packet to a broadcast port. One that is not a
      // beacon is not an error worth recording.
    }
  }

  /// The broadcast address of every subnet this device is on. Assumes /24 for the
  /// same reason the printer sweep does: Dart does not expose an interface netmask,
  /// and a shop router hands out a /24.
  Future<List<InternetAddress>> _broadcastTargets() async {
    final prefixes = <String>{};
    for (final address in await _localAddresses()) {
      final cut = address.lastIndexOf('.');
      if (cut < 0) continue;
      prefixes.add(address.substring(0, cut + 1));
    }
    return [
      for (final prefix in prefixes) ?_address('${prefix}255'),
    ];
  }

  static InternetAddress? _address(String value) {
    try {
      return InternetAddress(value);
    } catch (_) {
      return null;
    }
  }
}
