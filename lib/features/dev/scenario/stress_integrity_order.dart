import '../../../core/printing/print_probe.dart';
import '../../../domain/order.dart';
import '../stress_note.dart';
import 'stress_trace.dart';

/// Steps that wait on a printer. Their time is the printer's, so they are left
/// out of the slow-step check, which is about the till.
const Set<String> kPrinterSteps = {
  'kitchen',
  'receipt',
  'bag slip',
  'kitchen cancel',
  'timed fire',
};

String _tail(String uuid) => uuid.substring(0, 8);

bool _near(double a, double b) => (a - b).abs() <= 0.01;

/// Checks on one trace against what the till holds after the run.
class OrderChecks {
  OrderChecks({
    required this.byUuid,
    required this.records,
    required this.printing,
    required this.slow,
  });

  final Order? Function(String uuid) byUuid;
  final List<PrintRecord> records;
  final bool printing;
  final Duration slow;

  void run(OrderTrace t) {
    final p = t.problems;
    final err = t.error;
    if (err != null) {
      p.add(StressNote('Stopped: {error}', {'error': err}, true));
    }
    for (final e in t.events.where((e) => e.failed)) {
      p.add(
        StressNote('Step failed: {step} ({detail})', {
          'step': e.step,
          'detail': e.detail,
        }, true),
      );
    }
    for (final e in t.events) {
      if (kPrinterSteps.contains(e.step) || e.micros < slow.inMicroseconds) {
        continue;
      }
      p.add(
        StressNote('Slow step: {step} took {ms} ms', {
          'step': e.step,
          'ms': (e.micros / 1000).toStringAsFixed(0),
        }),
      );
    }
    for (final want in t.expected.values) {
      _stored(t, want);
    }
    _split(t);
    _timed(t);
    _prints(t);
  }

  void _stored(OrderTrace t, ExpectedOrder want) {
    final got = byUuid(want.uuid);
    if (want.gone) {
      if (got != null) {
        t.problems.add(
          StressNote('Should be gone but is still on the till: {order}', {
            'order': '#${got.displayNo}',
          }, true),
        );
      }
      return;
    }
    if (got == null) {
      t.problems.add(
        StressNote('Lost: {order} is not on the till any more', {
          'order': _tail(want.uuid),
        }, true),
      );
      return;
    }
    void differ(String field, Object? should, Object? actual) {
      if (should == actual) return;
      t.problems.add(
        StressNote(
          'Changed after the run: #{no} {field} should be {want}, is {got}',
          {
            'no': got.displayNo,
            'field': field,
            'want': '$should',
            'got': '$actual',
          },
          true,
        ),
      );
    }

    differ('state', want.state?.name, got.state.name);
    differ('lines', want.lineCount, got.lines.length);
    if (!_near(want.total, got.total)) {
      differ(
        'total',
        want.total.toStringAsFixed(2),
        got.total.toStringAsFixed(2),
      );
    }
    differ('table', want.table, got.tableLabel);
    differ('type', want.type?.name, got.type.name);
    differ('driver', want.driverId, got.driverId);
    differ('delivery', want.deliveryStatus?.name, got.deliveryStatus.name);
    differ('till', want.deviceId, got.deviceId);
    if (got.state == OrderState.paid && !_near(got.amountPaid, got.total)) {
      t.problems.add(
        StressNote('Paid {paid} of {total} on #{no}', {
          'paid': got.amountPaid.toStringAsFixed(2),
          'total': got.total.toStringAsFixed(2),
          'no': got.displayNo,
        }, true),
      );
    }
    if (got.state == OrderState.paid) {
      final unfired = got.lines.where((l) => !l.printedToKitchen).length;
      if (unfired > 0) {
        t.problems.add(
          StressNote(
            'Paid with {n} lines that never reached the kitchen: #{no}',
            {'n': unfired, 'no': got.displayNo},
            true,
          ),
        );
      }
    }
  }

  void _split(OrderTrace t) {
    final from = t.splitFrom;
    final main = t.uuid;
    if (from == null || main == null) return;
    var sum = 0.0;
    for (final u in [main, ...t.splitInto]) {
      sum += byUuid(u)?.total ?? 0;
    }
    if (_near(sum, from)) return;
    t.problems.add(
      StressNote('Split checks add up to {sum}, the bill was {total}', {
        'sum': sum.toStringAsFixed(2),
        'total': from.toStringAsFixed(2),
      }, true),
    );
  }

  void _timed(OrderTrace t) {
    final due = t.timedDue;
    if (due == null) return;
    final fired = t.timedFired;
    if (fired == null) {
      t.problems.add(
        const StressNote('Timed course never reached the kitchen', {}, true),
      );
      return;
    }
    final late = fired.difference(due);
    if (late > const Duration(seconds: 15)) {
      t.problems.add(
        StressNote('Timed course late by {s} s', {
          's': (late.inMilliseconds / 1000).toStringAsFixed(1),
        }, true),
      );
    }
  }

  void _prints(OrderTrace t) {
    if (!printing) return;
    for (final want in t.expected.values.where((w) => !w.gone)) {
      final got = byUuid(want.uuid);
      if (got == null) continue;
      for (final r in records.where((r) => r.orderUuid == want.uuid)) {
        final wrongNo = r.orderNo != got.orderNo;
        final wrongTotal =
            r.channel == PrintChannel.receipt &&
            r.total != null &&
            !_near(r.total!, got.total);
        if (!wrongNo && !wrongTotal) continue;
        t.problems.add(
          StressNote(
            '{paper} shows #{printed} / {ptotal}, the order is #{no} / {total}',
            {
              'paper': r.channel.name,
              'printed': r.orderNo ?? '-',
              'ptotal': r.total?.toStringAsFixed(2) ?? '-',
              'no': got.orderNo ?? '-',
              'total': got.total.toStringAsFixed(2),
            },
            true,
          ),
        );
      }
    }
    final main = t.uuid;
    if (main != null &&
        (t.type?.isDelivery ?? false) &&
        !records.any(
          (r) => r.orderUuid == main && r.channel == PrintChannel.bagSlip,
        )) {
      t.problems.add(
        const StressNote('No bag slip came out for this delivery', {}, true),
      );
    }
  }
}
