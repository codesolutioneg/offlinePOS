import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/features/dev/scenario/stress_day_runner.dart';
import 'package:offline_pos/features/dev/scenario/stress_deps.dart';
import 'package:offline_pos/features/dev/scenario/stress_table_pool.dart';

import '../db/sqlite_loader.dart';
import '../stress/stress_day_deps.dart';
import '../stress/stress_till.dart';

/// Two tills running a full day at once: the 17:50 run stopped ten orders on
/// "no free table" while thirty lab tables stood empty, and its first sales on
/// the secondary paid before the primary's numbers had arrived.
void main() {
  setUpAll(useSystemSqlite);

  late StressTill till;
  setUp(() => till = StressTill());
  tearDown(() => till.close());

  const config = StressDayConfig(
    mode: StressDayMode.fullDay,
    orders: 20,
    cashiers: 3,
    printing: false,
  );

  StressDeps with_({
    Future<bool> Function(String table)? reserveSeat,
    Future<void> Function()? readyToNumber,
  }) {
    final base = labDeps(till);
    return StressDeps(
      db: base.db,
      deviceId: base.deviceId,
      orders: base.orders,
      tables: base.tables,
      catalogue: base.catalogue,
      newSession: base.newSession,
      reserveSeat: reserveSeat,
      readyToNumber: readyToNumber,
    );
  }

  test('a floor held by the other till for a dozen tables is walked past', () async {
    final refused = <String>{};
    final deps = with_(reserveSeat: (table) async {
      if (refused.length < 12) refused.add(table);
      return !refused.contains(table);
    });

    final report = await StressDayRunner(deps: deps, pace: Duration.zero).run(config);

    expect(refused, hasLength(12));
    expect(report.traces.where((t) => t.error != null), isEmpty,
        reason: [for (final t in report.traces) if (t.error != null) t.error].join('\n'));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('the cashiers start once the primary\'s numbers are in', () async {
    DateTime? ready;
    final deps = with_(readyToNumber: () async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      ready = DateTime.now();
    });

    final report = await StressDayRunner(deps: deps, pace: Duration.zero).run(config);

    expect(ready, isNotNull);
    for (final t in report.traces) {
      expect(t.started.isBefore(ready!), isFalse, reason: '${t.index}');
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('two tills start their walk of the floor at different tables', () {
    final deps = labDeps(till);
    for (var i = 1; i <= 10; i++) {
      deps.tables.add(name: 'T$i', section: 'Main');
    }
    final a = StressTablePool(orders: deps.orders, tables: deps.tables, deviceId: 'till-a');
    final b = StressTablePool(orders: deps.orders, tables: deps.tables, deviceId: 'till-b');

    expect(a.take(), isNot(b.take()));
  });
}
