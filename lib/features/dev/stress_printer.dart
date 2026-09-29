import 'dart:async';

import '../../core/printing/kitchen_ticket.dart';
import '../../domain/order.dart';
import 'stress_note.dart';

/// Sends Stress Lab orders through the till's own kitchen and receipt paths, so
/// the printers see the same load a rush puts on them, and reports how they coped.
class StressPrinter {
  StressPrinter({this.fireKitchen, this.printReceipt});

  /// The till's kitchen fire and receipt print. Null in tests: nothing prints.
  final Future<KitchenFireResult> Function(Order order)? fireKitchen;
  final Future<void> Function(Order order)? printReceipt;

  /// Whether lab orders go to the printers. The screen sets it before each run.
  bool enabled = true;

  bool get available => fireKitchen != null;

  final List<Future<KitchenFireResult>> _tickets = [];
  final List<Future<void>> _receipts = [];

  /// Fire [order] to the kitchen and, when [receipt], print its receipt after,
  /// as the till's paid path does. Unawaited, as on the till: selling never waits.
  void queue(Order order, {required bool receipt}) {
    final fire = fireKitchen;
    if (!enabled || fire == null) return;
    final ticket = fire(order);
    _tickets.add(ticket);
    final print = printReceipt;
    if (receipt && print != null) _receipts.add(ticket.then((_) => print(order)));
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
    ];
  }
}
