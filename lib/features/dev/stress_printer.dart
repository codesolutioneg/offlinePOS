import 'dart:async';

import '../../core/printing/kitchen_ticket.dart';
import '../../core/printing/print_probe.dart';
import '../../domain/order.dart';
import 'stress_note.dart';

/// Sends Stress Lab orders through the till's own kitchen and receipt paths, so
/// the printers see the same load a rush puts on them, and reports how they coped.
class StressPrinter {
  StressPrinter({
    this.fireKitchen,
    this.printReceipt,
    this.heldPrints,
    this.attachProbe,
  });

  /// The till's kitchen fire and receipt print. Null in tests: nothing prints.
  final Future<KitchenFireResult> Function(Order order)? fireKitchen;
  final Future<void> Function(Order order)? printReceipt;

  /// How many jobs the till's print spool is holding right now.
  final int Function()? heldPrints;

  /// Installs (or, with null, removes) the probe the till's print paths report
  /// each job's destination to. Without it the run can only say the printer took
  /// the bytes, not whether the ticket landed on the pass or at the till.
  final void Function(PrintProbe? probe)? attachProbe;

  /// Whether lab orders go to the printers. The screen sets it before each run.
  bool enabled = true;

  bool get available => fireKitchen != null;

  final List<Future<KitchenFireResult>> _tickets = [];
  final List<Future<void>> _receipts = [];

  PrintProbe? _probe;
  int _heldBefore = 0;

  /// Fire [order] to the kitchen and, when [receipt], print its receipt after,
  /// as the till's paid path does. Unawaited, as on the till: selling never waits.
  void queue(Order order, {required bool receipt}) {
    final fire = fireKitchen;
    if (!enabled || fire == null) return;
    _startProbe();
    final ticket = fire(order);
    _tickets.add(ticket);
    final print = printReceipt;
    if (receipt && print != null) {
      _receipts.add(ticket.then((_) => print(order)));
    }
  }

  void _startProbe() {
    final attach = attachProbe;
    if (_probe != null || attach == null) return;
    _heldBefore = heldPrints?.call() ?? 0;
    attach(_probe = PrintProbe());
  }

  /// Wait for everything queued since the last drain, and say how it went.
  Future<List<StressNote>> drain() async {
    if (_tickets.isEmpty) return const [];
    final sw = Stopwatch()..start();
    const limit = Duration(minutes: 3);
    final results = await Future.wait(_tickets).timeout(limit, onTimeout: () => []);
    await Future.wait(_receipts).timeout(limit, onTimeout: () => []);
    final asked = _tickets.length;
    final receipts = _receipts.length;
    _tickets.clear();
    _receipts.clear();
    int count(KitchenFireResult r) => results.where((x) => x == r).length;
    final lost = count(KitchenFireResult.lost);
    final unanswered = asked - results.length;
    final probe = _probe;
    _probe = null;
    attachProbe?.call(null);
    return [
      StressNote(
        'Kitchen: {asked} orders · sent {sent} · spooled {spooled} · lost {lost} · '
        'no answer {none} · receipts {receipts} · printers done after {s} s',
        {
          'asked': asked,
          'sent': count(KitchenFireResult.sent),
          'spooled': count(KitchenFireResult.spooled),
          'lost': lost,
          'none': unanswered,
          'receipts': receipts,
          's': (sw.elapsedMilliseconds / 1000).toStringAsFixed(1),
        },
        lost > 0 || unanswered > 0,
      ),
      if (probe != null)
        ...paperNotes(
          probe,
          heldBefore: _heldBefore,
          heldAfter: heldPrints?.call() ?? 0,
        ),
    ];
  }
}

/// Where a run's paper actually went, per kind of slip, read off [p]. The spool
/// counts before and after say whether the run left the till holding jobs.
List<StressNote> paperNotes(
  PrintProbe p, {
  required int heldBefore,
  required int heldAfter,
}) {
  int k(PrintOutcome o) => p.count(PrintChannel.kitchen, o);
  int r(PrintOutcome o) => p.count(PrintChannel.receipt, o);
  int s(PrintOutcome o) => p.count(PrintChannel.subReceipt, o);
  final atTill =
      r(PrintOutcome.atPrinter) +
      k(PrintOutcome.onReceiptPrinter) +
      s(PrintOutcome.onReceiptPrinter);
  return [
    StressNote(
      'Kitchen tickets: {station} at the kitchen printer · {rerouted} on the receipt '
      'printer instead · {held} held · {lost} lost',
      {
        'station': k(PrintOutcome.atPrinter),
        'rerouted': k(PrintOutcome.onReceiptPrinter),
        'held': k(PrintOutcome.spooled),
        'lost': k(PrintOutcome.lost),
      },
      k(PrintOutcome.onReceiptPrinter) +
              k(PrintOutcome.spooled) +
              k(PrintOutcome.lost) >
          0,
    ),
    StressNote(
      'Receipts: {printed} printed · {held} held · {failed} failed',
      {
        'printed': r(PrintOutcome.atPrinter),
        'held': r(PrintOutcome.spooled),
        'failed': r(PrintOutcome.lost),
      },
      r(PrintOutcome.spooled) + r(PrintOutcome.lost) > 0,
    ),
    if (p.total(PrintChannel.subReceipt) > 0)
      StressNote(
        'Pass copies: {printed} printed · {rerouted} on the receipt printer · '
        '{held} held · {lost} lost',
        {
          'printed': s(PrintOutcome.atPrinter),
          'rerouted': s(PrintOutcome.onReceiptPrinter),
          'held': s(PrintOutcome.spooled),
          'lost': s(PrintOutcome.lost),
        },
        s(PrintOutcome.onReceiptPrinter) +
                s(PrintOutcome.spooled) +
                s(PrintOutcome.lost) >
            0,
      ),
    StressNote(
      'Held prints on this till: {before} before the run · {after} now',
      {'before': heldBefore, 'after': heldAfter},
      heldAfter > heldBefore,
    ),
    StressNote(
      'Count the paper: {kitchen} slips at the kitchen printer, {till} at the '
      'receipt printer',
      {'kitchen': k(PrintOutcome.atPrinter), 'till': atTill},
    ),
  ];
}
