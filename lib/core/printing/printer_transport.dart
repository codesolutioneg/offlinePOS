import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'spool_store.dart';

/// Where receipt bytes actually go.
abstract interface class PrinterTransport {
  Future<void> send(Uint8List bytes);
}

class PrinterUnavailable implements Exception {
  PrinterUnavailable(this.message);
  final String message;
  @override
  String toString() => 'PrinterUnavailable: $message';
}

/// A network printer on the shop's own LAN, spoken to directly over TCP 9100.
///
/// This is the whole reason printing survives an outage: the printer sits on the
/// same switch as the till, so the internet being down is irrelevant. Nothing here
/// touches the cloud, and nothing is rasterised, so a receipt costs what the printer
/// costs and no more.
///
/// Contrast with a browser POS served from the cloud, which cannot even reach a
/// plain-HTTP printer from an HTTPS page without a certificate dance.
class TcpPrinter implements PrinterTransport {
  TcpPrinter({
    required this.host,
    this.port = 9100,
    this.timeout = const Duration(seconds: 5),
    this.retries = 1,
    this.retryDelay = const Duration(milliseconds: 300),
    Future<Socket> Function(String host, int port, {Duration? timeout})? connect,
  }) : _connect = connect ?? _defaultConnect;

  final String host;
  final int port;

  /// Short on purpose. A jammed or powered-off printer must fail fast so the
  /// cashier can hand over a hand-written slip, not watch a spinner.
  final Duration timeout;

  /// One quick retry by default. On a mesh network a till roaming between access
  /// points drops the connection for a moment, and losing a kitchen ticket to a
  /// hand-off that resolves in 300 ms would be absurd.
  final int retries;
  final Duration retryDelay;

  final Future<Socket> Function(String host, int port, {Duration? timeout}) _connect;

  static Future<Socket> _defaultConnect(String host, int port, {Duration? timeout}) =>
      Socket.connect(host, port, timeout: timeout);

  @override
  Future<void> send(Uint8List bytes) async {
    Object? last;
    for (var attempt = 0; attempt <= retries; attempt++) {
      if (attempt > 0) await Future<void>.delayed(retryDelay);
      try {
        return await _sendOnce(bytes);
      } on PrinterUnavailable catch (e) {
        last = e;
      }
    }
    throw last!;
  }

  Future<void> _sendOnce(Uint8List bytes) async {
    Socket? socket;
    try {
      socket = await _connect(host, port, timeout: timeout);
      socket.add(bytes);
      await socket.flush().timeout(timeout);
    } on TimeoutException {
      throw PrinterUnavailable('$host:$port timed out');
    } on SocketException catch (e) {
      throw PrinterUnavailable('$host:$port ${e.osError?.message ?? e.message}');
    } finally {
      // Always let go of the socket: a thermal printer has very few connection
      // slots, and leaking one takes the printer out for the rest of the shift.
      await socket?.close().catchError((_) {});
      socket?.destroy();
    }
  }
}

/// Tries each printer in turn and returns on the first that accepts the job.
///
/// A kitchen with two printers should not stop taking orders because one is out of
/// paper, and a till with a spare should use it rather than lose the ticket.
class FallbackPrinter implements PrinterTransport {
  FallbackPrinter(this.printers, {this.onFallback});

  final List<PrinterTransport> printers;

  /// Called when a printer is skipped, so the failure is visible in support rather
  /// than silently absorbed.
  final void Function(int index, Object error)? onFallback;

  @override
  Future<void> send(Uint8List bytes) async {
    if (printers.isEmpty) throw PrinterUnavailable('no printers configured');
    Object? last;
    for (var i = 0; i < printers.length; i++) {
      try {
        await printers[i].send(bytes);
        return;
      } catch (e) {
        last = e;
        onFallback?.call(i, e);
      }
    }
    throw PrinterUnavailable('all ${printers.length} printers failed: $last');
  }
}

/// Holds jobs a printer could not take, so they can be reprinted rather than lost.
///
/// A receipt that never printed is a customer without proof of payment and a kitchen
/// without a ticket. The sale itself is already safe on disk; this keeps the paper
/// side recoverable too, including across the restart a till gets every night.
///
/// Where the backlog lives is the [SpoolStore]'s business. Hand it a durable one on
/// a real till: an in-memory spool is only recoverable until closing time, which is
/// precisely when someone closes the app.
class SpooledPrinter implements PrinterTransport {
  SpooledPrinter(
    this._inner, {
    SpoolStore? spool,
    this.maxSpool = 100,
    this.onDropped,
  }) : _spool = spool ?? MemorySpoolStore();

  final PrinterTransport _inner;
  final SpoolStore _spool;

  /// The backlog is capped so a printer left off for a week cannot fill the disk.
  final int maxSpool;

  /// Called for every job the cap forces out. A discarded receipt is a customer
  /// with no proof of payment, so it is never dropped quietly.
  final void Function(SpooledJob job)? onDropped;

  bool _flushing = false;

  int get spooledCount => _spool.count;
  bool get hasSpooled => spooledCount > 0;

  Future<List<SpooledJob>> held({int limit = 50}) =>
      _spool.oldestFirst(limit: limit);

  /// [reference] is the order the receipt belongs to, so a held one can be named
  /// on the support screen instead of being an anonymous count.
  @override
  Future<void> send(Uint8List bytes, {String? reference}) async {
    try {
      await _inner.send(bytes);
    } catch (e) {
      await _spool.add(bytes, reference: reference);
      for (final dropped in await _spool.trimTo(maxSpool)) {
        onDropped?.call(dropped);
      }
      rethrow;
    }
  }

  /// Send immediately, bypassing the spool: on failure it throws and queues
  /// nothing. For payloads that must not be replayed later, above all a cash-drawer
  /// kick, which would pop the till open unexpectedly when the backlog flushes.
  Future<void> sendNow(Uint8List bytes) => _inner.send(bytes);

  /// Retry the backlog, oldest first. Stops at the first failure so the order in
  /// which tickets print is preserved.
  ///
  /// Safe to call from a timer and from a support button at the same time: the
  /// second caller does nothing rather than printing everything twice.
  Future<int> flush() async {
    if (_flushing) return 0;
    _flushing = true;
    try {
      var printed = 0;
      for (final job in await _spool.oldestFirst()) {
        try {
          await _inner.send(job.bytes);
        } catch (e) {
          await _spool.markFailed(job.id, e.toString());
          break;
        }
        await _spool.remove(job.id);
        printed++;
      }
      return printed;
    } finally {
      _flushing = false;
    }
  }
}
