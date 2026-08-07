import 'dart:async';
import 'dart:io';

import 'printer_discovery.dart';

/// How a printer says who it is, independently of the address it currently holds.
///
/// Defaults to the reverse-DNS name the printer registered with the router's DHCP
/// server, which is the closest thing to a MAC address reachable over a plain TCP
/// socket.
typedef PrinterIdentifier = Future<String?> Function(String host, int port);

/// A printer the shop configured, remembered by name rather than by address.
class ConfiguredPrinter {
  const ConfiguredPrinter({
    required this.name,
    this.host,
    this.port = 9100,
    this.identity,
    this.lastSeenAt,
  });

  /// The stable, human-chosen identity: 'kitchen', 'bar', 'receipt'. Receipts are
  /// routed by this and never by address.
  final String name;

  /// Last address that answered. A hint, not an identity: the lease can move.
  final String? host;

  final int port;

  /// What the printer called itself last time it answered. This is what survives a
  /// DHCP change and lets a rescan tell the kitchen printer from the bar one.
  final String? identity;

  final DateTime? lastSeenAt;

  ConfiguredPrinter copyWith({
    String? host,
    int? port,
    String? identity,
    DateTime? lastSeenAt,
  }) =>
      ConfiguredPrinter(
        name: name,
        host: host ?? this.host,
        port: port ?? this.port,
        identity: identity ?? this.identity,
        lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      );

  Map<String, Object?> toMap() => {
        'name': name,
        'host': host,
        'port': port,
        'identity': identity,
        'last_seen_at': lastSeenAt?.toUtc().toIso8601String(),
      };

  /// Returns null for a row that cannot be trusted, so one corrupt record cannot
  /// take the whole printer configuration down with it.
  static ConfiguredPrinter? fromMap(Map<String, Object?> map) {
    final name = map['name'];
    if (name is! String || name.isEmpty) return null;
    final seen = map['last_seen_at'];
    return ConfiguredPrinter(
      name: name,
      host: map['host'] is String ? map['host'] as String : null,
      port: map['port'] is int ? map['port'] as int : 9100,
      identity: map['identity'] is String ? map['identity'] as String : null,
      lastSeenAt: seen is String ? DateTime.tryParse(seen) : null,
    );
  }
}

/// Resolves a configured printer to an address that is answering right now.
///
/// The address a printer had at installation is not its identity. On mesh wifi with
/// DHCP the lease moves, and a hardcoded address means the kitchen stops getting
/// tickets with nothing in the app looking broken. So the registry keeps the name,
/// tries the last known address first because that is almost always still right,
/// and falls back to sweeping the subnet when it is not.
///
/// Persistence is deliberately not here: [toMap] and [PrinterRegistry.fromMap] hand
/// a plain map to whatever owns storage.
class PrinterRegistry {
  PrinterRegistry({
    required PrinterDiscovery discovery,
    PrinterIdentifier? identify,
    this.onChanged,
    this.identityTimeout = const Duration(milliseconds: 500),
    this.resolveBudget = const Duration(seconds: 4),
    this.rediscoveryBackoff = const Duration(seconds: 45),
    DateTime Function()? now,
  })  : _discovery = discovery,
        _identify = identify ?? _reverseDns,
        _now = now ?? DateTime.now;

  /// Restores a saved configuration. Anything unreadable in [saved] is skipped
  /// rather than thrown: a mangled preferences blob must not stop the till printing.
  factory PrinterRegistry.fromMap(
    Map<String, Object?> saved, {
    required PrinterDiscovery discovery,
    PrinterIdentifier? identify,
    void Function()? onChanged,
    Duration identityTimeout = const Duration(milliseconds: 500),
    Duration resolveBudget = const Duration(seconds: 4),
    Duration rediscoveryBackoff = const Duration(seconds: 45),
    DateTime Function()? now,
  }) {
    final registry = PrinterRegistry(
      discovery: discovery,
      identify: identify,
      onChanged: onChanged,
      identityTimeout: identityTimeout,
      resolveBudget: resolveBudget,
      rediscoveryBackoff: rediscoveryBackoff,
      now: now,
    );
    final rows = saved['printers'];
    if (rows is Iterable) {
      for (final row in rows) {
        if (row is! Map) continue;
        final printer = ConfiguredPrinter.fromMap(row.cast<String, Object?>());
        if (printer != null) registry._printers[printer.name] = printer;
      }
    }
    return registry;
  }

  final PrinterDiscovery _discovery;
  final PrinterIdentifier _identify;
  final DateTime Function() _now;

  /// Fired when something worth writing to disk changed: a new address or a newly
  /// learned identity. Not fired for a plain confirmation, so printing a ticket
  /// does not cost a database write.
  final void Function()? onChanged;

  /// Hard ceiling on one identity lookup.
  ///
  /// Reverse DNS is the single most likely thing to be broken during an outage:
  /// the router is up so the printer is reachable, but the upstream forwarder the
  /// router points at is gone, and the resolver then sits on its own timeout,
  /// which is seconds per nameserver. No identity is a valid answer everywhere one
  /// is used, so waiting past this buys nothing.
  final Duration identityTimeout;

  /// Ceiling on one whole resolution, sweep and identity lookups together. The
  /// sale is already committed by the time anything here runs, but the kitchen is
  /// waiting on the ticket.
  final Duration resolveBudget;

  /// How long a failed sweep is believed before another one is worth the cost.
  ///
  /// A printer that is switched off does not come back within a ticket, and
  /// sweeping a /24 per receipt is hundreds of connections a minute across the same
  /// wifi the tills are roaming on. The last known address is still probed every
  /// time, because that one connection is what notices it came back; only the sweep
  /// waits.
  final Duration rediscoveryBackoff;

  final Map<String, ConfiguredPrinter> _printers = {};
  final Map<String, Future<String?>> _resolving = {};
  final Set<String> _identityAsked = {};
  final Map<String, DateTime> _sweepFailedAt = {};

  Iterable<ConfiguredPrinter> get printers => _printers.values;

  ConfiguredPrinter? operator [](String name) => _printers[name];

  /// Configures a printer, or points an existing one at a new address.
  void remember(String name, {String? host, int port = 9100}) {
    final existing = _printers[name];
    _printers[name] = ConfiguredPrinter(
      name: name,
      host: host,
      port: port,
      // An address entered by hand may be a different unit, so the learned identity
      // is dropped rather than carried onto whatever now answers there.
      identity: existing != null && existing.host == host ? existing.identity : null,
      lastSeenAt: existing != null && existing.host == host ? existing.lastSeenAt : null,
    );
    _identityAsked.remove(name);
    // Pointing the till somewhere new is an explicit statement that the world
    // changed, so an earlier failed sweep stops counting.
    _sweepFailedAt.remove(name);
    onChanged?.call();
  }

  void forget(String name) {
    if (_printers.remove(name) == null) return;
    _identityAsked.remove(name);
    _sweepFailedAt.remove(name);
    onChanged?.call();
  }

  /// The address for [name] that is answering now, or null if the printer cannot be
  /// found. Never throws.
  ///
  /// The last known address is tried first, so the ordinary case is one connection
  /// and no sweep.
  Future<String?> resolve(String name) {
    // Two tickets printing at once must not each sweep the subnet.
    final inFlight = _resolving[name];
    if (inFlight != null) return inFlight;
    final pending = _locate(name, tryLastKnown: true);
    _resolving[name] = pending;
    return pending.whenComplete(() => _resolving.remove(name));
  }

  /// Sweeps for [name] ignoring the last known address, for when support knows the
  /// printer moved and does not want to wait for a failed connect to prove it.
  ///
  /// This is also the "I know something changed" signal, so it sweeps even inside
  /// the cooling-off period a failed sweep would otherwise impose.
  Future<String?> refresh(String name) => _locate(name, tryLastKnown: false);

  /// Whether a sweep for [name] is currently being held off because the last one
  /// found nothing. Support can see why the till is not looking.
  bool sweepHeldOffFor(String name) {
    final failedAt = _sweepFailedAt[name];
    return failedAt != null &&
        _now().difference(failedAt) < rediscoveryBackoff;
  }

  /// The whole configuration as plain data, for whatever owns persistence.
  Map<String, Object?> toMap() => {
        'printers': [for (final printer in _printers.values) printer.toMap()],
      };

  Future<String?> _locate(String name, {required bool tryLastKnown}) async {
    final printer = _printers[name];
    if (printer == null) return null;

    final spent = Stopwatch()..start();
    Duration left() => resolveBudget - spent.elapsed;

    final lastKnown = printer.host;
    if (tryLastKnown &&
        lastKnown != null &&
        await _discovery.probe(lastKnown, port: printer.port)) {
      _sweepFailedAt.remove(name);
      return _confirm(name, lastKnown);
    }

    // The address is stale or there never was one. Sweeping is the right answer to
    // a printer that moved and the wrong answer to a printer that is switched off,
    // and the two look identical from here, so a sweep that finds nothing buys a
    // cooling-off period. Without it a dead printer costs a full subnet sweep per
    // receipt, for as long as it stays dead.
    if (tryLastKnown && sweepHeldOffFor(name)) return null;

    final candidates =
        await _discovery.scan(port: printer.port, budget: left());
    if (candidates.isEmpty) return _sweptAndFoundNothing(name);

    if (printer.identity != null) {
      for (final candidate in candidates) {
        if (left() <= Duration.zero) break;
        if (await _identityOf(candidate.host, candidate.port) == printer.identity) {
          _sweepFailedAt.remove(name);
          return _confirm(name, candidate.host);
        }
      }
      // Something is answering, but not this printer. Adopting a stranger would send
      // steak orders to the bar; a missing ticket is the lesser failure.
      return _sweptAndFoundNothing(name);
    }

    if (candidates.length == 1) {
      _sweepFailedAt.remove(name);
      return _confirm(name, candidates.single.host);
    }

    // Several printers answer and none of them has ever told us who it is, so there
    // is nothing to match on. Support picks, rather than the till guessing.
    return _sweptAndFoundNothing(name);
  }

  String? _sweptAndFoundNothing(String name) {
    _sweepFailedAt[name] = _now();
    return null;
  }

  Future<String?> _confirm(String name, String host) async {
    final before = _printers[name];
    if (before == null) return null;

    final moved = before.host != host;
    _printers[name] = before.copyWith(host: host, lastSeenAt: _now());
    if (moved) onChanged?.call();

    // Learned behind the answer, never in front of it. An identity is only ever
    // used to tell two printers apart on some later sweep, so gating the address on
    // it puts a name lookup between the kitchen and its ticket for no benefit at
    // all. Asked once per session, and again after a move.
    if (before.identity == null && (moved || _identityAsked.add(name))) {
      unawaited(_learnIdentity(name, host, before.port));
    }
    return host;
  }

  Future<void> _learnIdentity(String name, String host, int port) async {
    final identity = await _identityOf(host, port);
    if (identity == null) return;
    final current = _printers[name];
    // Reconfigured, forgotten or moved again while the lookup was out. The name
    // belongs to whatever answers now, not to the address this started against.
    if (current == null || current.host != host || current.identity != null) return;
    _printers[name] = current.copyWith(identity: identity);
    onChanged?.call();
  }

  /// An identity is a hint used to pick between candidates, so it gets a hard
  /// deadline and no answer is a perfectly good one. A resolver that hangs, or one
  /// an integrator wired up badly, must not take down the print path.
  Future<String?> _identityOf(String host, int port) async {
    try {
      return await _identify(host, port).timeout(identityTimeout);
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _reverseDns(String host, int _) async {
    final resolved = await InternetAddress(host).reverse();
    // No PTR record: the resolver hands back the address it was given, which
    // identifies nothing.
    return resolved.host == host ? null : resolved.host.toLowerCase();
  }
}
