import 'dart:async';

import '../../app/pos_session.dart';
import '../../core/db/catalogue_store.dart';
import '../../core/db/table_store.dart';
import '../../domain/catalogue.dart';
import '../../domain/order.dart';
import 'latency_stats.dart';
import 'stress_lab_store.dart';
import 'stress_note.dart';
import 'stress_printer.dart';

/// Whether this build carries the Stress Lab. Off unless the till is started
/// with `--dart-define=STRESS_LAB=true`, so a shop build never shows it.
const bool kStressLabEnabled = bool.fromEnvironment('STRESS_LAB');

/// What one Stress Lab run produced. [title] is the English source the screen
/// translates.
class StressReport {
  StressReport(this.title,
      {this.done = 0, this.failed = 0, this.latency, List<StressNote>? notes})
      : notes = notes ?? [];

  final String title;
  final int done;
  final int failed;
  final LatencyStats? latency;
  final List<StressNote> notes;
}

/// Drives cashier scenarios through a real [PosSession] on the live database.
///
/// Every order it makes carries [kStressNote], so [StressLabStore.cleanup] can
/// take all of it back out of the orders table and the Odoo queue.
class StressLabRunner {
  StressLabRunner({
    required this.session,
    required this.catalogue,
    required this.tables,
    required this.store,
    StressPrinter? printer,
  }) : printer = printer ?? StressPrinter();

  final PosSession session;
  final CatalogueStore catalogue;
  final TableStore tables;
  final StressLabStore store;

  /// The till's own kitchen and receipt printing, so a lab order prints exactly
  /// as a cashier's does.
  final StressPrinter printer;

  void _print(Order order, {required bool receipt}) =>
      printer.queue(order, receipt: receipt);

  Future<List<StressNote>> _drainPrinting() => printer.drain();

  late final List<Product> _menu = _pickMenu();
  late final PaymentMethod _tender = _pickTender();

  List<Product> _pickMenu() {
    final real = catalogue.products(limit: 40).where((p) => p.price > 0).toList();
    if (real.isNotEmpty) return real;
    return [
      for (var i = 1; i <= 12; i++)
        Product(id: 990000 + i, name: 'Stress item $i', price: 25.0 + i * 5),
    ];
  }

  PaymentMethod _pickTender() {
    final methods = catalogue.paymentMethods();
    return methods.where((m) => m.isCash).firstOrNull ??
        methods.firstOrNull ??
        const PaymentMethod(id: 1, name: 'Cash', isCash: true);
  }

  void _ring(int seed) {
    final lines = 3 + seed % 4;
    for (var i = 0; i < lines; i++) {
      session.addProduct(_menu[(seed * 7 + i) % _menu.length], qty: 1 + (i % 2).toDouble());
    }
    session.setNote(kStressNote);
  }

  int _payTimed() {
    final due = session.current.total;
    final sw = Stopwatch()..start();
    final sale = session.pay(
      payments: [OrderPayment(methodId: _tender.id, amount: due)],
      cashReceived: due,
    );
    final us = sw.elapsedMicroseconds;
    if (sale == null) throw StateError('nothing on the counter to pay');
    _print(sale, receipt: true);
    return us;
  }

  /// Ring and pay [count] takeaway orders spread evenly over [over].
  Future<StressReport> flood(int count, Duration over, StressProgress onProgress) async {
    session.startFresh(OrderType.takeaway);
    final gap = count > 0 ? over ~/ count : Duration.zero;
    final timings = <int>[];
    final notes = <StressNote>[];
    var failed = 0;
    final clock = Stopwatch()..start();
    for (var i = 0; i < count; i++) {
      try {
        _ring(i);
        timings.add(_payTimed());
      } catch (e) {
        failed++;
        if (notes.length < 5) {
          notes.add(StressNote('Order {n} failed: {error}', {'n': i + 1, 'error': '$e'}, true));
        }
      }
      onProgress(i + 1, count);
      await Future<void>.delayed(gap > Duration.zero ? gap : const Duration(milliseconds: 1));
    }
    notes.insert(0, StressNote('{n} orders in {s} s', {
      'n': count,
      's': (clock.elapsedMilliseconds / 1000).toStringAsFixed(1),
    }));
    notes.addAll(await _drainPrinting());
    notes.addAll(store.auditNumbers());
    return StressReport('Order flood', done: timings.length, failed: failed,
        latency: LatencyStats(timings), notes: notes);
  }

  /// Open a tab on every free table (adding [kStressSection] tables if the floor
  /// has none free), the way a full dining room looks at 9pm.
  Future<StressReport> fillTables(StressProgress onProgress) async {
    session.startFresh(OrderType.dineIn);
    var free = store.freeTables();
    final notes = <StressNote>[];
    if (free.isEmpty) {
      for (var i = 1; i <= 30; i++) {
        tables.add(name: 'S$i', section: kStressSection);
      }
      notes.add(const StressNote('No free table on the floor: added 30 in section "{section}"',
          {'section': kStressSection}));
      free = store.freeTables();
    }
    final timings = <int>[];
    for (var i = 0; i < free.length; i++) {
      _ring(i);
      final tab = session.current;
      final sw = Stopwatch()..start();
      session.hold(table: free[i].name);
      timings.add(sw.elapsedMicroseconds);
      _print(tab, receipt: false);
      onProgress(i + 1, free.length);
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    // The tickets write the tabs back once printed, so they finish before any
    // settle can recall one.
    notes.addAll(await _drainPrinting());
    notes.addAll(store.auditNumbers());
    return StressReport('Fill every table', done: free.length,
        latency: LatencyStats(timings), notes: notes);
  }

  /// Recall and pay every table the lab opened.
  Future<StressReport> settleTables(StressProgress onProgress) async {
    final tabs = store.stressTabs();
    final timings = <int>[];
    for (var i = 0; i < tabs.length; i++) {
      if (session.recall(tabs[i].uuid)) timings.add(_payTimed());
      onProgress(i + 1, tabs.length);
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    return StressReport('Settle the tables', done: tabs.length,
        latency: LatencyStats(timings),
        notes: [...await _drainPrinting(), ...store.auditNumbers()]);
  }

  /// Load [count] old sales, then time 20 fresh payments on the fuller till.
  Future<StressReport> growAndTime(int count, StressProgress onProgress) async {
    await store.seedHistory(count, onProgress);
    session.startFresh(OrderType.takeaway);
    final timings = <int>[];
    for (var i = 0; i < 20; i++) {
      _ring(i);
      timings.add(_payTimed());
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    return StressReport('Pay on a full till', done: timings.length,
        latency: LatencyStats(timings),
        notes: [
          StressNote('{n} sales on the till while timing', {'n': store.totalSales()}),
          ...await _drainPrinting(),
        ]);
  }
}
