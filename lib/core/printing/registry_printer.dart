import 'dart:typed_data';

import 'escpos.dart';
import 'printer_registry.dart';
import 'printer_transport.dart';
import 'raster_line.dart';

/// Sends to whichever address the named printer answers on right now, and to the
/// spare when it answers on none.
///
/// The registry resolves a name to an address per job, so the socket has to be built
/// per job too. Wrapping that here rather than at the call site is what lets a
/// [SpooledPrinter] sit above it and survive a printer changing address: the spool
/// belongs to 'kitchen', not to an IP that moved last night.
///
/// The spare is tried before the spool, because a shop with two printers would
/// rather read the ticket off the wrong one now than off the right one when someone
/// notices. It is marked on the paper: a slip that came out somewhere unexpected has
/// to say why, or the bar spends the night wondering whose steak order this is.
class RegistryPrinter implements PrinterTransport {
  RegistryPrinter(this.registry, this.name);

  final PrinterRegistry registry;

  /// The stable name the receipt is routed by: 'receipt', 'kitchen', 'bar'.
  final String name;

  @override
  Future<void> send(Uint8List bytes) async {
    final printer = registry[name];
    if (printer == null) throw PrinterUnavailable('no $name printer configured');
    // A kitchen ticket reaches a station without passing a spool, so this is where
    // its Arabic lines become dots. Bytes with nothing deferred come back as they
    // went in, and it happens once for both printers.
    final job = await rasteriseEscPos(bytes);
    try {
      await _sendTo(name, job);
    } on PrinterUnavailable catch (dead) {
      final spare = printer.backup;
      // No spare, or one that has been forgotten since: the job is spooled by the
      // caller rather than sent somewhere it does not belong.
      if (spare == null || spare == name || registry[spare] == null) rethrow;
      try {
        await _sendTo(spare, _rerouted(job));
      } on PrinterUnavailable {
        // Both are gone. The original failure is what is thrown, so the job spools
        // against the printer it was meant for and reprints there when it is back.
        throw dead;
      }
    }
  }

  Future<void> _sendTo(String printerName, Uint8List job) async {
    final printer = registry[printerName];
    if (printer == null) {
      throw PrinterUnavailable('no $printerName printer configured');
    }
    final host = await registry.resolve(printerName);
    // Nothing on the subnet answered, or several unidentified printers did and the
    // registry refused to guess between them.
    if (host == null) {
      throw PrinterUnavailable('$printerName printer not found on the LAN');
    }
    await registry.transportTo(host, printer.port).send(job);
  }

  /// The same job with a banner saying where it should have gone.
  ///
  /// Prepended rather than woven in: the job starts with its own `ESC @`, so the
  /// banner is printed and the printer is then reset into exactly the state the job
  /// expects. Nothing inside the document is touched, which also means a rendered
  /// line keeps the bytes it was rendered into.
  Uint8List _rerouted(Uint8List job) {
    final header = (EscPos()
          ..reset()
          ..align(EscPosAlign.center)
          ..bold(true)
          ..line('*** REROUTED FROM ${name.toUpperCase()} ***')
          ..bold(false)
          ..align(EscPosAlign.left)
          ..feed())
        .build();
    return Uint8List.fromList([...header, ...job]);
  }
}
