import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/stress_purge.dart';
import 'package:offline_pos/core/printing/print_probe.dart';
import 'package:offline_pos/features/dev/scenario/stress_day_runner.dart';
import 'package:offline_pos/features/dev/scenario/stress_integrity.dart';
import 'package:offline_pos/features/dev/scenario/stress_trace.dart';
import 'package:offline_pos/features/dev/stress_lab_store.dart';

import '../db/sqlite_loader.dart';
import '../stress/stress_day_deps.dart';
import '../stress/stress_till.dart';

void main() {
  setUpAll(useSystemSqlite);

  late StressTill till;
  setUp(() => till = StressTill());
  tearDown(() => till.close());

  StressDayRunner runner() =>
      StressDayRunner(deps: labDeps(till), pace: Duration.zero);

  String problemsOf(StressDayReport r) => [
    for (final t in r.traces.where((t) => t.hasProblems))
      '${t.index} ${t.scenario}: ${t.error ?? ''} '
          '${t.problems.map((p) => p.fill(p.template)).join(' | ')}',
  ].join('\n');

  test('every cashier flow of a full day runs clean on one till', () async {
    final report = await runner().run(
      const StressDayConfig(
        mode: StressDayMode.fullDay,
        orders: 20,
        cashiers: 3,
        printing: false,
      ),
    );

    expect(report.traces, hasLength(20));
    expect(
      report.traces.map((t) => t.scenario).toSet(),
      kFullDayScenarios.keys.toSet(),
    );
    expect(report.withProblems, 0, reason: problemsOf(report));
    expect(report.notes.where((n) => n.alarm), isEmpty);
    expect(stressOrderCount(till.db), greaterThan(0));

    final store = StressLabStore(
      db: till.db,
      orders: till.orders,
      tables: labDeps(till).tables,
    );
    await store.cleanup();
    expect(stressOrderCount(till.db), 0);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('the delivery run walks every delivery type to delivered', () async {
    final report = await runner().run(
      const StressDayConfig(
        mode: StressDayMode.deliveryOnly,
        orders: 6,
        cashiers: 2,
        printing: false,
      ),
    );

    expect(report.withProblems, 0, reason: problemsOf(report));
    expect(report.traces.map((t) => t.type).toSet(), hasLength(3));
  });

  group('integrity reads the till back and names what went wrong', () {
    late OrderTrace trace;
    late String uuid;

    setUp(() async {
      final report = await runner().run(
        const StressDayConfig(
          mode: StressDayMode.fullDay,
          orders: 1,
          cashiers: 1,
          printing: false,
        ),
      );
      trace = report.traces.single;
      expect(trace.hasProblems, isFalse, reason: problemsOf(report));
      uuid = trace.uuid!;
    });

    List<String> recheck({List<PrintRecord> records = const []}) {
      trace.problems.clear();
      StressIntegrity(
        db: till.db,
        orders: till.orders,
        deviceId: till.deviceId,
        records: records,
        printing: records.isNotEmpty,
      ).check([trace]);
      return [for (final p in trace.problems.where((p) => p.alarm)) p.template];
    }

    test('a clean order raises nothing', () => expect(recheck(), isEmpty));

    test('an order written over after the run', () {
      final o = till.orders.byUuid(uuid)!;
      o.lines.removeLast();
      till.orders.save(o);
      expect(recheck(), contains(startsWith('Changed after the run')));
    });

    test('a number handed out twice', () {
      final s = labSession(till, 'other');
      till.ring(s, lines: 1);
      final twin = till.payCash(s);
      twin.orderNo = trace.orderNo;
      till.orders.save(twin);
      expect(recheck(), contains('Number #{no} is also on {others}'));
    });

    test('a receipt that quotes another order', () {
      final o = till.orders.byUuid(uuid)!;
      final wrong = PrintRecord(
        channel: PrintChannel.receipt,
        outcome: PrintOutcome.atPrinter,
        orderUuid: uuid,
        orderNo: 'X-0001',
        total: o.total + 10,
      );
      expect(recheck(records: [wrong]), contains(startsWith('{paper} shows')));
    });

    test('an order that vanished from the till', () {
      till.db.raw.execute('DELETE FROM orders WHERE uuid = ?', [uuid]);
      expect(recheck(), contains(startsWith('Lost:')));
    });

    test('a sale missing from the Odoo queue', () {
      till.db.raw.execute(
        "DELETE FROM outbox WHERE kind = 'order.push' AND payload_uuid = ?",
        [uuid],
      );
      expect(recheck(), contains('Paid but not in the Odoo queue'));
    });
  });
}
