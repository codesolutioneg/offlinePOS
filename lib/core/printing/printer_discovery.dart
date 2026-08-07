import 'dart:async';
import 'dart:io';

/// A host on the shop LAN that accepted a TCP connection on the printer port.
class DiscoveredPrinter {
  const DiscoveredPrinter(this.host, this.port);

  final String host;
  final int port;

  @override
  bool operator ==(Object other) =>
      other is DiscoveredPrinter && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => '$host:$port';
}

/// Finds receipt printers by sweeping the till's own subnet for hosts that accept
/// TCP on the printer port.
///
/// Printers live on the shop LAN, which is exactly why they keep working during an
/// internet outage, but the shop runs mesh wifi: the till roams between access
/// points and DHCP leases drift, so the address written down at installation goes
/// stale and the kitchen quietly stops getting tickets. Rediscovering locally costs
/// nothing and needs no cloud.
///
/// The sweep is bounded on purpose. A cashier waiting on a ticket cannot wait for
/// 254 sequential connects, so hosts are probed concurrently with a short timeout
/// and an optional overall budget.
class PrinterDiscovery {
  PrinterDiscovery({
    this.port = 9100,
    this.probeTimeout = const Duration(milliseconds: 300),
    this.concurrency = 32,
    Future<Socket> Function(String host, int port, {Duration? timeout})? connect,
    Future<List<String>> Function()? localAddresses,
  })  : _connect = connect ?? _defaultConnect,
        _localAddresses = localAddresses ?? _defaultLocalAddresses;

  final int port;

  /// A printer on the same switch answers in single-digit milliseconds. Anything
  /// slower than this is a host that is not going to answer at all, and waiting on
  /// it just makes the whole sweep longer.
  final Duration probeTimeout;

  /// How many hosts are in flight at once. Enough to sweep a /24 in a few rounds,
  /// low enough that a cheap access point does not drop connections under the burst.
  final int concurrency;

  final Future<Socket> Function(String host, int port, {Duration? timeout}) _connect;
  final Future<List<String>> Function() _localAddresses;

  static Future<Socket> _defaultConnect(String host, int port, {Duration? timeout}) =>
      Socket.connect(host, port, timeout: timeout);

  static Future<List<String>> _defaultLocalAddresses() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    return [
      for (final interface in interfaces)
        for (final address in interface.addresses) address.address,
    ];
  }

  /// Sweeps every subnet the device is on and returns the hosts that answered, in
  /// ascending address order.
  ///
  /// Never throws. A till that cannot enumerate its interfaces still has to sell, so
  /// a broken sweep is an empty result, not an exception on the print path.
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async {
    final probePort = port ?? this.port;
    final targets = await _targets();
    if (targets.isEmpty) return const [];

    // Slots keep the result in subnet order regardless of which probe finishes
    // first, so support sees a stable list between runs.
    final hits = List<DiscoveredPrinter?>.filled(targets.length, null);
    final elapsed = Stopwatch()..start();
    var next = 0;

    Future<void> worker() async {
      while (true) {
        if (budget != null && elapsed.elapsed >= budget) return;
        final i = next++;
        if (i >= targets.length) return;
        if (await probe(targets[i], port: probePort)) {
          hits[i] = DiscoveredPrinter(targets[i], probePort);
        }
      }
    }

    final workers = concurrency < targets.length ? concurrency : targets.length;
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    return [for (final hit in hits) ?hit];
  }

  /// Whether [host] accepts a connection on the printer port right now.
  ///
  /// Answers false rather than throwing, for every way a probe can fail: refused,
  /// timed out, unroutable, or an interface that disappeared mid-sweep.
  Future<bool> probe(String host, {int? port}) async {
    try {
      final connecting = _connect(host, port ?? this.port, timeout: probeTimeout);
      // A connect that loses the race with the timeout can still succeed afterwards,
      // with nothing left holding it. A thermal printer has very few connection
      // slots, and leaking one takes it out for the rest of the shift.
      unawaited(connecting.then((socket) => socket.destroy(), onError: (_) {}));
      final socket = await connecting.timeout(probeTimeout);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<List<String>> _targets() async {
    List<String> addresses;
    try {
      addresses = await _localAddresses();
    } catch (_) {
      return const [];
    }

    final prefixes = <String>{};
    final targets = <String>[];
    for (final address in addresses) {
      final cut = address.lastIndexOf('.');
      if (cut < 0) continue;
      final prefix = address.substring(0, cut + 1);
      if (!prefixes.add(prefix)) continue;
      // Assumes /24. Dart does not expose an interface's netmask, and every shop
      // router hands out a /24; guessing wider would turn a two-second sweep into
      // a several-minute one for addresses nothing is ever assigned from.
      for (var host = 1; host <= 254; host++) {
        targets.add('$prefix$host');
      }
    }
    return targets;
  }
}
