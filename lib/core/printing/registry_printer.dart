import 'dart:typed_data';

import 'printer_registry.dart';
import 'printer_transport.dart';
import 'raster_line.dart';

/// Sends to whichever address the named printer answers on right now.
///
/// The registry resolves a name to an address per job, so the socket has to be built
/// per job too. Wrapping that here rather than at the call site is what lets a
/// [SpooledPrinter] sit above it and survive a printer changing address: the spool
/// belongs to 'kitchen', not to an IP that moved last night.
class RegistryPrinter implements PrinterTransport {
  RegistryPrinter(this.registry, this.name);

  final PrinterRegistry registry;

  /// The stable name the receipt is routed by: 'receipt', 'kitchen', 'bar'.
  final String name;

  @override
  Future<void> send(Uint8List bytes) async {
    final printer = registry[name];
    if (printer == null) throw PrinterUnavailable('no $name printer configured');
    final host = await registry.resolve(name);
    // Nothing on the subnet answered, or several unidentified printers did and the
    // registry refused to guess between them. Either way the job is spooled by the
    // caller rather than sent somewhere it does not belong.
    if (host == null) throw PrinterUnavailable('$name printer not found on the LAN');
    // A kitchen ticket reaches a station without passing a spool, so this is where
    // its Arabic lines become dots. Bytes with nothing deferred come back as they
    // went in.
    await TcpPrinter(host: host, port: printer.port)
        .send(await rasteriseEscPos(bytes));
  }
}
