import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/printing/printer_discovery.dart';

/// A connect that never answers, standing in for the overwhelming majority of a
/// subnet: addresses with nothing on them behind an access point that drops rather
/// than refuses.
Future<Socket> silence(String host, int port, {Duration? timeout}) =>
    Completer<Socket>().future;

void main() {
  late ServerSocket printer;
  late int deadPort;

  // Bound once for the whole file, not once per test. Opening a listening socket
  // is the one operation here that can stall the test isolate for seconds at a
  // time, and four of these tests never touch a real socket at all, so paying for
  // a fresh bind before each of them buys nothing and costs the timing tests their
  // headroom. The server is stateless anyway: it accepts and drops.
  setUpAll(() async {
    printer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    printer.listen((socket) => socket.destroy());

    // Bound and immediately released, so the port is real but nothing is behind it.
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    deadPort = closed.port;
    await closed.close();
  });
  tearDownAll(() async => printer.close());

  test('finds a listening printer on the subnet', () async {
    final discovery = PrinterDiscovery(
      port: printer.port,
      localAddresses: () async => ['127.0.0.1'],
    );

    expect(await discovery.scan(), contains(DiscoveredPrinter('127.0.0.1', printer.port)));
  });

  test('ignores hosts that refuse', () async {
    final discovery = PrinterDiscovery(
      port: deadPort,
      localAddresses: () async => ['127.0.0.1'],
    );

    expect(await discovery.scan(), isEmpty);
  });

  test('a scan is bounded in time even when most hosts never answer', () async {
    final discovery = PrinterDiscovery(
      port: printer.port,
      probeTimeout: const Duration(milliseconds: 100),
      localAddresses: () async => ['10.0.0.5'],
      connect: (host, port, {timeout}) => host == '10.0.0.77'
          ? Socket.connect(InternetAddress.loopbackIPv4, port, timeout: timeout)
          : silence(host, port, timeout: timeout),
    );

    final elapsed = Stopwatch()..start();
    final found = await discovery.scan();
    elapsed.stop();

    // 254 hosts, 32 at a time, 100 ms each is eight rounds. Nowhere near the
    // 25 seconds the same sweep would take one host at a time.
    expect(elapsed.elapsed, lessThan(const Duration(seconds: 5)));
    expect(found.single.host, '10.0.0.77');
  });

  test('a scan stops at its budget rather than holding up a ticket', () async {
    final discovery = PrinterDiscovery(
      probeTimeout: const Duration(milliseconds: 200),
      localAddresses: () async => ['10.0.0.5'],
      connect: silence,
    );

    final elapsed = Stopwatch()..start();
    await discovery.scan(budget: const Duration(milliseconds: 50));
    elapsed.stop();

    // The budget is checked between probes, so it gives up after the first round
    // instead of the eight rounds an unbudgeted sweep of this subnet would take.
    expect(elapsed.elapsed, lessThan(const Duration(seconds: 1)));
  });

  test('discovery never throws; it returns what it found', () async {
    final discovery = PrinterDiscovery(
      port: printer.port,
      localAddresses: () async => ['127.0.0.1'],
      connect: (host, port, {timeout}) {
        if (host == '127.0.0.1') return Socket.connect(host, port, timeout: timeout);
        throw StateError('interface went away mid-sweep');
      },
    );

    expect(await discovery.scan(), [DiscoveredPrinter('127.0.0.1', printer.port)]);
  });

  test('a till with no usable network finds nothing rather than failing', () async {
    final discovery = PrinterDiscovery(
      localAddresses: () async => throw const SocketException('no interfaces'),
    );

    expect(await discovery.scan(), isEmpty);
  });

  test('the subnet swept is the one the till is actually on', () async {
    final probed = <String>[];
    final discovery = PrinterDiscovery(
      probeTimeout: const Duration(milliseconds: 10),
      localAddresses: () async => ['192.168.8.31'],
      connect: (host, port, {timeout}) async {
        probed.add(host);
        throw const SocketException('refused');
      },
    );

    await discovery.scan();

    // Every host on the till's own /24, and nothing outside it. A roaming till that
    // lands on a different subnet sweeps that one instead, with no reconfiguration.
    expect(probed, hasLength(254));
    expect(probed.toSet(), containsAll(<String>['192.168.8.1', '192.168.8.254']));
    expect(probed, isNot(contains('192.168.8.0')));
    expect(probed, isNot(contains('192.168.8.255')));
  });
}
