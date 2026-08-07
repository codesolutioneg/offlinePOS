import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/printing/printer_transport.dart';

final job = Uint8List.fromList([0x1b, 0x40, 65, 66, 67]);

class Recording implements PrinterTransport {
  Recording({this.failTimes = 0});
  int failTimes;
  int calls = 0;
  final List<Uint8List> received = [];
  @override
  Future<void> send(Uint8List bytes) async {
    calls++;
    if (failTimes > 0) {
      failTimes--;
      throw PrinterUnavailable('down');
    }
    received.add(bytes);
  }
}

void main() {
  group('TcpPrinter against a real socket', () {
    late ServerSocket server;
    late Completer<List<int>> firstJob;

    // Bound once for the whole group. Opening a listening socket is the one
    // operation here that can stall the test isolate for seconds at a time, and
    // the server holds no per-test state: the completer it reports through is the
    // one belonging to whichever test is running.
    setUpAll(() async {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((socket) {
        final buffer = <int>[];
        socket.listen(buffer.addAll, onDone: () {
          if (!firstJob.isCompleted) firstJob.complete(buffer);
          socket.destroy();
        });
      });
    });
    tearDownAll(() async => server.close());

    // Complete on the first full job rather than polling a fixed number of
    // times, which loses the race when the suite runs in parallel.
    setUp(() => firstJob = Completer<List<int>>());

    test('sends the bytes over the LAN, with no cloud involved', () async {
      final printer = TcpPrinter(host: server.address.address, port: server.port);
      await printer.send(job);
      expect(await firstJob.future.timeout(const Duration(seconds: 10)), job);
    });

    test('a printer that is off fails fast rather than hanging the till', () async {
      final printer = TcpPrinter(
        host: '127.0.0.1', port: 1, retries: 0,
        timeout: const Duration(milliseconds: 300),
      );
      expect(() => printer.send(job), throwsA(isA<PrinterUnavailable>()));
    });

    test('a roaming blip is retried rather than losing the ticket', () async {
      var attempts = 0;
      final printer = TcpPrinter(
        host: server.address.address,
        port: server.port,
        retries: 2,
        retryDelay: const Duration(milliseconds: 10),
        connect: (h, p, {timeout}) async {
          attempts++;
          // First attempt fails as if the access point handed over mid-connect.
          if (attempts == 1) throw const SocketException('network changed');
          return Socket.connect(h, p, timeout: timeout);
        },
      );
      await printer.send(job);
      expect(attempts, 2);
    });
  });

  group('FallbackPrinter', () {
    test('uses the spare when the first printer is out', () async {
      final dead = Recording(failTimes: 1);
      final spare = Recording();
      final skipped = <int>[];
      await FallbackPrinter([dead, spare], onFallback: (i, _) => skipped.add(i))
          .send(job);
      expect(spare.received.single, job);
      // The failure is visible to support, not silently absorbed.
      expect(skipped, [0]);
    });

    test('reports when every printer is out', () async {
      expect(
        () => FallbackPrinter([Recording(failTimes: 1), Recording(failTimes: 1)]).send(job),
        throwsA(isA<PrinterUnavailable>()),
      );
    });

    test('no printers configured is an error, not a silent no-op', () async {
      expect(() => FallbackPrinter([]).send(job), throwsA(isA<PrinterUnavailable>()));
    });
  });

  group('SpooledPrinter', () {
    test('a failed ticket is kept so it can be reprinted', () async {
      final inner = Recording(failTimes: 1);
      final spooled = SpooledPrinter(inner);
      await expectLater(spooled.send(job), throwsA(isA<PrinterUnavailable>()));
      expect(spooled.spooledCount, 1);
      expect(await spooled.flush(), 1);
      expect(spooled.hasSpooled, isFalse);
      expect(inner.received.single, job);
    });

    test('flushing stops at the first failure so tickets print in order', () async {
      final inner = Recording(failTimes: 3);
      final spooled = SpooledPrinter(inner);
      for (var i = 0; i < 3; i++) {
        await spooled.send(job).catchError((_) {});
      }
      expect(spooled.spooledCount, 3);
      expect(await spooled.flush(), 3);
    });

    test('the spool is bounded so a printer left off cannot exhaust memory', () async {
      final spooled = SpooledPrinter(Recording(failTimes: 999), maxSpool: 5);
      for (var i = 0; i < 20; i++) {
        await spooled.send(job).catchError((_) {});
      }
      expect(spooled.spooledCount, 5);
    });
  });
}
