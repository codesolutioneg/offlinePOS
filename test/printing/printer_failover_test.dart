import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/printing/printer_discovery.dart';
import 'package:offline_pos/core/printing/printer_registry.dart';
import 'package:offline_pos/core/printing/printer_transport.dart';
import 'package:offline_pos/core/printing/registry_printer.dart';
import 'package:offline_pos/core/printing/spool_store.dart';

import 'strip_escpos.dart';

/// Only the hosts in [answering] are on the wire, and no sweep ever finds anything
/// else. A printer that is switched off is simply not in the set.
class _Subnet extends PrinterDiscovery {
  _Subnet(this.answering);

  final Set<String> answering;

  @override
  Future<bool> probe(String host, {int? port}) async => answering.contains(host);

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async =>
      const [];
}

/// A printer that records what it was handed.
class _Paper implements PrinterTransport {
  _Paper(this.host);

  final String host;
  final List<Uint8List> jobs = [];

  @override
  Future<void> send(Uint8List bytes) async => jobs.add(bytes);
}

Future<String?> _anonymous(String host, int port) async => null;

/// A dead printer already spools and reprints. What is proved here is the step
/// before that: a shop with a spare gets the ticket now, on the spare, and the paper
/// says where it should have gone.
void main() {
  late Map<String, _Paper> papers;

  PrinterRegistry registryWith(Set<String> answering) {
    papers = {};
    return PrinterRegistry(
      discovery: _Subnet(answering),
      identify: _anonymous,
      open: (host, port) => papers.putIfAbsent(host, () => _Paper(host)),
    );
  }

  List<Uint8List> printedAt(String host) => papers[host]?.jobs ?? const [];

  final ticket = Uint8List.fromList('STEAK\n'.codeUnits);

  test('a dead printer with a spare prints at the spare, marked', () async {
    final registry = registryWith({'192.168.1.60'});
    registry.remember('kitchen', host: '192.168.1.50', backup: 'bar');
    registry.remember('bar', host: '192.168.1.60');

    await RegistryPrinter(registry, 'kitchen').send(ticket);

    expect(printedAt('192.168.1.50'), isEmpty);
    expect(printedAt('192.168.1.60'), hasLength(1));
    final slip = strippedText(printedAt('192.168.1.60').single);
    expect(slip, contains('REROUTED FROM KITCHEN'));
    expect(slip, contains('STEAK'));
  });

  test('the spare is followed by name, not by the address it had', () async {
    // The bar printer moved overnight and is answering somewhere else entirely.
    final registry = registryWith({'192.168.1.77'});
    registry.remember('kitchen', host: '192.168.1.50', backup: 'bar');
    registry.remember('bar', host: '192.168.1.60');

    // Only a sweep would find it, and nothing sweeps here, so the reroute fails and
    // the job is thrown back for the spool. The point is that the address it once
    // had is never used blindly.
    await expectLater(
        RegistryPrinter(registry, 'kitchen').send(ticket),
        throwsA(isA<PrinterUnavailable>()));
    expect(printedAt('192.168.1.60'), isEmpty);
    expect(printedAt('192.168.1.77'), isEmpty);
  });

  test('with both printers dead the job spools against the one it was meant for',
      () async {
    final registry = registryWith(<String>{});
    registry.remember('kitchen', host: '192.168.1.50', backup: 'bar');
    registry.remember('bar', host: '192.168.1.60');
    final spool = MemorySpoolStore();
    final printer =
        SpooledPrinter(RegistryPrinter(registry, 'kitchen'), spool: spool);

    await expectLater(
        printer.send(ticket, reference: 'kot-1'), throwsA(isA<PrinterUnavailable>()));

    final held = await spool.oldestFirst();
    expect(held, hasLength(1));
    // What is held is the job itself, with no reroute banner on it: it is going to
    // the kitchen printer when that comes back.
    expect(strippedText(held.single.bytes), isNot(contains('REROUTED')));
    expect(strippedText(held.single.bytes), contains('STEAK'));
  });

  test('a printer with no spare behaves exactly as it did before', () async {
    final registry = registryWith({'192.168.1.60'});
    registry.remember('kitchen', host: '192.168.1.50');
    registry.remember('bar', host: '192.168.1.60');

    await expectLater(RegistryPrinter(registry, 'kitchen').send(ticket),
        throwsA(isA<PrinterUnavailable>()));
    // The bar is alive and untouched: nothing is rerouted without being asked for.
    expect(printedAt('192.168.1.60'), isEmpty);
  });

  test('a live printer never mentions a spare it did not need', () async {
    final registry = registryWith({'192.168.1.50', '192.168.1.60'});
    registry.remember('kitchen', host: '192.168.1.50', backup: 'bar');
    registry.remember('bar', host: '192.168.1.60');

    await RegistryPrinter(registry, 'kitchen').send(ticket);

    expect(printedAt('192.168.1.60'), isEmpty);
    expect(strippedText(printedAt('192.168.1.50').single), isNot(contains('REROUTED')));
  });

  test('a spare that has been forgotten since is not chased', () async {
    final registry = registryWith(<String>{});
    registry.remember('kitchen', host: '192.168.1.50', backup: 'bar');

    await expectLater(RegistryPrinter(registry, 'kitchen').send(ticket),
        throwsA(isA<PrinterUnavailable>()));
  });

  group('what is remembered', () {
    test('a printer is never its own spare', () {
      final registry = registryWith(<String>{});
      registry.remember('kitchen', host: '192.168.1.50', backup: 'kitchen');
      expect(registry['kitchen']!.backup, isNull);

      registry.setBackup('kitchen', 'kitchen');
      expect(registry['kitchen']!.backup, isNull);
    });

    test('the spare survives a re-point and can be cleared', () {
      final registry = registryWith(<String>{});
      registry.remember('kitchen', host: '192.168.1.50', backup: 'bar');

      registry.remember('kitchen', host: '192.168.1.51');
      expect(registry['kitchen']!.backup, 'bar');

      registry.setBackup('kitchen', null);
      expect(registry['kitchen']!.backup, isNull);
    });

    test('it is written down and read back', () {
      final registry = registryWith(<String>{});
      registry.remember('kitchen', host: '192.168.1.50', backup: 'bar');

      final restored = PrinterRegistry.fromMap(registry.toMap(),
          discovery: _Subnet(<String>{}), identify: _anonymous);
      expect(restored['kitchen']!.backup, 'bar');
    });
  });
}
