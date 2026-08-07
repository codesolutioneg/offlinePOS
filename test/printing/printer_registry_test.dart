import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/printing/printer_discovery.dart';
import 'package:offline_pos/core/printing/printer_registry.dart';

/// Nothing is listening here, so a probe is refused straight away. Stands in for
/// the address a printer held before its DHCP lease moved.
const staleHost = '192.168.8.40';

/// Printers do not answer a reverse lookup in the test environment, and a real one
/// would put a DNS round trip in the middle of every assertion.
Future<String?> anonymous(String host, int port) async => null;

/// Discovery with the subnet sweep standing still.
///
/// What the registry has to get right is *which* address it adopts and how often it
/// goes looking. Driving that through a real /24 costs 255 sockets per assertion,
/// which buries the thing under test and, on a host with a small ephemeral port
/// range, starves later tests of a port to bind. Whether a sweep finds a real
/// printer is [PrinterDiscovery]'s guarantee, and it is proved against real sockets
/// in printer_discovery_test.dart.
class StillSubnet extends PrinterDiscovery {
  StillSubnet([Set<String>? answering]) : answering = answering ?? <String>{};

  /// The hosts accepting connections on the printer port right now. Mutable, so a
  /// test can switch a printer back on partway through.
  final Set<String> answering;

  /// Addresses tried directly, without a sweep.
  final List<String> probed = [];

  /// The deadline each sweep was given, so a test can prove one was.
  final List<Duration?> budgets = [];

  int sweeps = 0;

  @override
  Future<bool> probe(String host, {int? port}) async {
    probed.add(host);
    return answering.contains(host);
  }

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async {
    sweeps++;
    budgets.add(budget);
    final hosts = answering.toList()..sort();
    return [for (final host in hosts) DiscoveredPrinter(host, port ?? this.port)];
  }
}

/// A resolver whose answer never arrives.
///
/// This is what reverse DNS looks like during an outage: the router is up so the
/// printer is reachable, but the forwarder the router points at is gone.
Future<String?> neverAnswers(String host, int port) =>
    Completer<String?>().future;

void main() {
  test('the last known host is tried first, so the common case costs one connection',
      () async {
    final subnet = StillSubnet({staleHost});
    final registry = PrinterRegistry(discovery: subnet, identify: anonymous)
      ..remember('kitchen', host: staleHost);

    expect(await registry.resolve('kitchen'), staleHost);
    expect(subnet.probed, [staleHost]);
    expect(subnet.sweeps, 0, reason: 'a ticket must not sweep the subnet');
  });

  test('a printer whose IP changed is found again at its new address', () async {
    final subnet = StillSubnet({'192.168.8.77'});
    final registry = PrinterRegistry(discovery: subnet, identify: anonymous)
      ..remember('kitchen', host: staleHost);

    expect(await registry.resolve('kitchen'), '192.168.8.77');
    // The new address is remembered, so the next ticket is one connection again.
    expect(registry['kitchen']!.host, '192.168.8.77');
  });

  test('refresh sweeps without waiting for the old address to fail', () async {
    final subnet = StillSubnet({'192.168.8.77'});
    final registry = PrinterRegistry(discovery: subnet, identify: anonymous)
      ..remember('kitchen', host: staleHost);

    expect(await registry.refresh('kitchen'), '192.168.8.77');
    // The stale address got no head start, which is the point of asking for a
    // refresh at all.
    expect(subnet.probed, isEmpty);
    expect(subnet.sweeps, 1);
  });

  test('a printer that is switched off resolves to nothing rather than throwing',
      () async {
    final subnet = StillSubnet();
    final registry = PrinterRegistry(discovery: subnet, identify: anonymous)
      ..remember('kitchen', host: staleHost);

    expect(await registry.resolve('kitchen'), isNull);
    // The last known address is kept: it is the best guess for when it comes back.
    expect(registry['kitchen']!.host, staleHost);
  });

  test('an unconfigured printer resolves to nothing', () async {
    final subnet = StillSubnet({staleHost});
    final registry = PrinterRegistry(discovery: subnet);

    expect(await registry.resolve('bar'), isNull);
    expect(subnet.probed, isEmpty);
    expect(subnet.sweeps, 0);
  });

  test('two tickets at once sweep the subnet once, not twice', () async {
    final subnet = StillSubnet({'192.168.8.77'});
    final registry = PrinterRegistry(discovery: subnet, identify: anonymous)
      ..remember('kitchen', host: staleHost);

    final both = await Future.wait([
      registry.resolve('kitchen'),
      registry.resolve('kitchen'),
    ]);

    expect(both, ['192.168.8.77', '192.168.8.77']);
    // One failed probe of the stale address, and one sweep behind both tickets.
    expect(subnet.probed, [staleHost]);
    expect(subnet.sweeps, 1);
  });

  group('nothing on the print path waits on a name lookup', () {
    test('a ticket is not held up by a resolver that never answers', () async {
      final subnet = StillSubnet({staleHost});
      final registry = PrinterRegistry(discovery: subnet, identify: neverAnswers)
        ..remember('kitchen', host: staleHost);

      // The printer accepted the very first probe. The address it answered on is
      // the answer, and an identity is only ever a tiebreak on some later sweep,
      // so nothing here is worth a DNS round trip in front of the kitchen ticket.
      expect(
        await registry.resolve('kitchen').timeout(const Duration(seconds: 2)),
        staleHost,
      );
    });

    test('an identity learned late is still remembered for the next sweep',
        () async {
      final subnet = StillSubnet({staleHost});
      late final PrinterRegistry registry;
      final learned = Completer<void>();
      registry = PrinterRegistry(
        discovery: subnet,
        identify: (host, port) async => 'kitchen-printer',
        onChanged: () {
          if (registry['kitchen']?.identity != null && !learned.isCompleted) {
            learned.complete();
          }
        },
      );
      registry.remember('kitchen', host: staleHost);

      expect(await registry.resolve('kitchen'), staleHost);
      await learned.future.timeout(const Duration(seconds: 2));
      expect(registry['kitchen']!.identity, 'kitchen-printer');
    });

    test('a stalled resolver cannot make a sweep run forever', () async {
      // Here the identity genuinely has to be asked, because two printers answer
      // and only one of them is ours. Per-candidate waits with no ceiling would
      // make this unbounded.
      final registry = PrinterRegistry.fromMap(
        {
          'printers': [
            {'name': 'kitchen', 'host': '10.0.0.99', 'identity': 'kitchen-printer'},
          ],
        },
        discovery: StillSubnet({'10.0.0.20', '10.0.0.30'}),
        identify: neverAnswers,
        identityTimeout: const Duration(milliseconds: 50),
        resolveBudget: const Duration(milliseconds: 400),
      );

      expect(
        await registry.resolve('kitchen').timeout(const Duration(seconds: 3)),
        isNull,
      );
    });
  });

  group('a printer that is off is not hunted for on every ticket', () {
    test('three tickets against a dead printer cost one sweep, not three',
        () async {
      final subnet = StillSubnet();
      final registry = PrinterRegistry(discovery: subnet, identify: anonymous)
        ..remember('kitchen', host: staleHost);

      for (var ticket = 0; ticket < 3; ticket++) {
        expect(await registry.resolve('kitchen'), isNull);
      }

      // A sweep is hundreds of connections across the same wifi the tills are
      // roaming on. Repeating it per receipt for as long as a printer stays
      // switched off is a self-inflicted outage during a rush.
      expect(subnet.sweeps, 1);
      // The last known address is still tried every time: that one connection is
      // what notices the printer came back.
      expect(subnet.probed, [staleHost, staleHost, staleHost]);
    });

    test('the sweep is time-boxed rather than open-ended', () async {
      final subnet = StillSubnet();
      final registry = PrinterRegistry(
        discovery: subnet,
        identify: anonymous,
        resolveBudget: const Duration(seconds: 2),
      )..remember('kitchen');

      await registry.resolve('kitchen');
      expect(subnet.budgets.single, isNotNull,
          reason: 'a cashier waiting on a ticket cannot wait for a whole /24');
    });

    test('the hold-off expires, so a printer switched back on is found again',
        () async {
      var clock = DateTime(2026, 3, 4, 19);
      final subnet = StillSubnet();
      final registry = PrinterRegistry(
        discovery: subnet,
        identify: anonymous,
        rediscoveryBackoff: const Duration(seconds: 45),
        now: () => clock,
      )..remember('kitchen', host: staleHost);

      expect(await registry.resolve('kitchen'), isNull);

      clock = clock.add(const Duration(minutes: 1));
      subnet.answering.add('192.168.8.77');

      expect(await registry.resolve('kitchen'), '192.168.8.77');
      expect(subnet.sweeps, 2);
    });

    test('a rescan looks straight away, hold-off or not', () async {
      final subnet = StillSubnet();
      final registry = PrinterRegistry(discovery: subnet, identify: anonymous)
        ..remember('kitchen', host: staleHost);

      expect(await registry.resolve('kitchen'), isNull);
      subnet.answering.add('192.168.8.77');

      // Support pressing Rescan is the explicit "I know something changed".
      expect(await registry.refresh('kitchen'), '192.168.8.77');
      expect(registry.sweepHeldOffFor('kitchen'), isFalse);
    });
  });

  group('when several printers answer', () {
    late StillSubnet subnet;
    final names = {'10.0.0.20': 'bar-printer', '10.0.0.30': 'kitchen-printer'};

    setUp(() => subnet = StillSubnet(names.keys.toSet()));

    test('the one that identifies itself as ours is the one adopted', () async {
      final registry = PrinterRegistry.fromMap(
        {
          'printers': [
            {'name': 'kitchen', 'host': '10.0.0.99', 'identity': 'kitchen-printer'},
          ],
        },
        discovery: subnet,
        identify: (host, port) async => names[host],
      );

      expect(await registry.resolve('kitchen'), '10.0.0.30');
    });

    test('it refuses to guess when nothing on the subnet says who it is', () async {
      final registry = PrinterRegistry(discovery: subnet, identify: anonymous)
        ..remember('kitchen', host: '10.0.0.99');

      // Sending steak orders to the bar printer is worse than not printing.
      expect(await registry.resolve('kitchen'), isNull);
    });

    test('a printer that is off is not replaced by whatever else answers', () async {
      final registry = PrinterRegistry.fromMap(
        {
          'printers': [
            {'name': 'grill', 'host': '10.0.0.99', 'identity': 'grill-printer'},
          ],
        },
        discovery: subnet,
        identify: (host, port) async => names[host],
      );

      expect(await registry.resolve('grill'), isNull);
    });
  });

  group('saving and loading', () {
    test('the configuration survives a round trip through a plain map', () async {
      final saved = (PrinterRegistry(discovery: StillSubnet())
            ..remember('kitchen', host: '192.168.8.40', port: 9100)
            ..remember('bar', host: '192.168.8.41', port: 9101))
          .toMap();

      final restored = PrinterRegistry.fromMap(saved, discovery: StillSubnet());

      expect(restored.printers.map((p) => p.name), ['kitchen', 'bar']);
      expect(restored['bar']!.host, '192.168.8.41');
      expect(restored['bar']!.port, 9101);
    });

    test('a saved blob that got mangled does not stop the till printing', () async {
      final registry = PrinterRegistry.fromMap(
        {
          'printers': [
            'not a printer',
            {'host': '192.168.8.40'},
            {'name': 'kitchen', 'host': '192.168.8.41', 'port': 'nine thousand'},
          ],
        },
        discovery: StillSubnet(),
      );

      expect(registry.printers.map((p) => p.name), ['kitchen']);
      expect(registry['kitchen']!.port, 9100);
    });

    test('confirming a printer before every ticket does not ask for a save',
        () async {
      var saves = 0;
      final registry = PrinterRegistry(
        discovery: StillSubnet({staleHost}),
        identify: anonymous,
        onChanged: () => saves++,
      )..remember('kitchen', host: staleHost);

      await registry.resolve('kitchen');
      await registry.resolve('kitchen');

      // Only the configuration itself was worth writing.
      expect(saves, 1);
    });

    test('a moved printer asks to be saved, so the next boot starts at the new address',
        () async {
      var saves = 0;
      final registry = PrinterRegistry(
        discovery: StillSubnet({'192.168.8.77'}),
        identify: anonymous,
        onChanged: () => saves++,
      )..remember('kitchen', host: staleHost);

      await registry.resolve('kitchen');

      expect(saves, 2);
    });
  });
}
