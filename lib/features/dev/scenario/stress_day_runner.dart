import 'dart:async';

import '../../../core/printing/print_probe.dart';
import '../../../domain/catalogue.dart';
import '../latency_stats.dart';
import '../stress_lab_store.dart';
import '../stress_note.dart';
import '../stress_printer.dart';
import 'delivery_scenarios.dart';
import 'dine_in_scenarios.dart';
import 'split_scenarios.dart';
import 'stress_cashier.dart';
import 'stress_deps.dart';
import 'stress_integrity.dart';
import 'stress_integrity_order.dart';
import 'stress_table_pool.dart';
import 'stress_timed.dart';
import 'stress_trace.dart';

enum StressDayMode { fullDay, deliveryOnly }

/// What the floor's config dialog asks before a run.
class StressDayConfig {
  const StressDayConfig({
    required this.mode,
    this.orders = 40,
    this.cashiers = 3,
    this.printing = true,
  });

  final StressDayMode mode;
  final int orders;
  final int cashiers;
  final bool printing;
}

typedef StressScenario = Future<void> Function(StressCashier c, OrderTrace t);

/// Every cashier flow a full day goes through, by the name the report uses.
const Map<String, StressScenario> kFullDayScenarios = {
  'takeaway': takeawayScenario,
  'hold & recall': holdRecallScenario,
  'timed send': timedSendScenario,
  'transfer': transferScenario,
  'merge': mergeScenario,
  'split by items': splitItemsScenario,
  'split check': splitCheckScenario,
  'split by persons': splitPersonsScenario,
  'void after kitchen': voidScenario,
  'delivery': deliveryScenario,
};

/// What one full-day run produced.
class StressDayReport {
  StressDayReport({
    required this.config,
    required this.device,
    required this.started,
    required this.finished,
    required this.traces,
    required this.notes,
    required this.latency,
  });

  final StressDayConfig config;
  final String device;
  final DateTime started;
  final DateTime finished;
  final List<OrderTrace> traces;
  final List<StressNote> notes;

  /// Every till step, printer waits left out.
  final LatencyStats latency;

  int get withProblems => traces.where((t) => t.hasProblems).length;
}

/// Runs [StressDayConfig.orders] scenarios over several virtual cashiers at once
/// on this till's live database, then reads the till back for what went wrong.
///
/// Every order it makes is a lab order (see [kStressNote]): it never reaches
/// Odoo or Dishflow and the Stress Lab's Clean up takes it all back out.
class StressDayRunner {
  StressDayRunner({
    required this.deps,
    this.pace = const Duration(milliseconds: 40),
  });

  final StressDeps deps;
  final Duration pace;

  Future<StressDayReport> run(
    StressDayConfig config, {
    StressProgress? onProgress,
  }) async {
    final d = config.printing && deps.prints ? deps : deps.withoutPrinting();
    final started = DateTime.now();
    final probe = PrintProbe();
    final heldBefore = d.heldPrints?.call() ?? 0;
    d.attachProbe?.call(probe);
    final traces = <OrderTrace>[];
    try {
      final cashiers = _cashiers(d, config.cashiers);
      final names = config.mode == StressDayMode.fullDay
          ? kFullDayScenarios.keys.toList()
          : const ['delivery'];
      var next = 0;
      var done = 0;
      Future<void> work(StressCashier c) async {
        while (next < config.orders) {
          final i = next++;
          final name = names[i % names.length];
          final t = OrderTrace(
            index: i + 1,
            scenario: name,
            cashier: c.id,
            device: d.deviceId,
          );
          traces.add(t);
          try {
            await kFullDayScenarios[name]!(c, t);
          } catch (e) {
            t.error = '$e';
            c.session.newOrder();
          }
          t.finished = DateTime.now();
          onProgress?.call(++done, config.orders);
          await c.pause();
        }
      }

      await Future.wait(cashiers.map(work));
    } finally {
      d.attachProbe?.call(null);
    }
    traces.sort((a, b) => a.index.compareTo(b.index));
    final checks = StressIntegrity(
      db: d.db,
      orders: d.orders,
      deviceId: d.deviceId,
      records: probe.records,
      printing: d.prints,
    ).check(traces);
    final finished = DateTime.now();
    return StressDayReport(
      config: config,
      device: d.deviceId,
      started: started,
      finished: finished,
      traces: traces,
      latency: LatencyStats([
        for (final t in traces)
          for (final e in t.events)
            if (e.micros > 0 && !kPrinterSteps.contains(e.step)) e.micros,
      ]),
      notes: [
        _summary(traces, finished.difference(started)),
        ...checks,
        if (d.prints)
          ...paperNotes(
            probe,
            heldBefore: heldBefore,
            heldAfter: d.heldPrints?.call() ?? 0,
          ),
        ..._byScenario(traces),
      ],
    );
  }

  List<StressCashier> _cashiers(StressDeps d, int count) {
    final menu = _menu(d);
    final methods = d.catalogue.paymentMethods();
    final tender =
        methods.where((m) => m.isCash).firstOrNull ??
        methods.firstOrNull ??
        const PaymentMethod(id: 1, name: 'Cash', isCash: true);
    final tables = StressTablePool(orders: d.orders, tables: d.tables);
    final ticker = StressTimedTicker();
    return [
      for (var k = 1; k <= count.clamp(1, 8); k++)
        StressCashier(
          id: 'stress-$k',
          deps: d,
          // Read the counter now, before any cashier has a bill on it: a session
          // that first looks later parks every other cashier's open bill.
          session: d.newSession('stress-$k')..current,
          menu: menu,
          tender: tender,
          tables: tables,
          ticker: ticker,
          seed: k * 7919,
          pace: pace,
        ),
    ];
  }

  static List<Product> _menu(StressDeps d) {
    final real = d.catalogue
        .products(limit: 40)
        .where((p) => p.price > 0)
        .toList();
    return [
      ...real,
      // Enough distinct items that a bill of four is four lines to split and move.
      for (var i = real.length; i < 8; i++)
        Product(
          id: 990001 + i,
          name: 'Stress item ${i + 1}',
          price: 25.0 + i * 5,
        ),
    ];
  }

  static StressNote _summary(List<OrderTrace> traces, Duration took) =>
      StressNote(
        '{n} orders · {bad} with problems · {stopped} stopped · {s} s',
        {
          'n': traces.length,
          'bad': traces.where((t) => t.hasProblems).length,
          'stopped': traces.where((t) => t.error != null).length,
          's': (took.inMilliseconds / 1000).toStringAsFixed(1),
        },
        traces.any((t) => t.hasProblems),
      );

  static List<StressNote> _byScenario(List<OrderTrace> traces) {
    final by = <String, List<OrderTrace>>{};
    for (final t in traces) {
      by.putIfAbsent(t.scenario, () => []).add(t);
    }
    return [
      for (final e in by.entries)
        StressNote(
          '{scenario}: {n} run · {bad} with problems',
          {
            'scenario': e.key,
            'n': e.value.length,
            'bad': e.value.where((t) => t.hasProblems).length,
          },
          e.value.any((t) => t.hasProblems),
        ),
    ];
  }
}
