import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/db/database.dart';

import '../db/sqlite_loader.dart';

void main() {
  late Db db;
  late AuditLog log;
  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    log = AuditLog(db);
  });
  tearDown(() => db.close());

  test('an action taken offline is still recorded', () {
    log.record('sara', 'pin.unlock', detail: 'offline');
    expect(log.unsyncedCount, 1);
    expect(log.unsynced().single['event'], 'pin.unlock');
  });

  test('entries stay unsynced until acknowledged, then stop being listed', () {
    log.record('sara', 'a');
    log.record('sara', 'b');
    final ids = log.unsynced().map((e) => e['id'] as int).toList();
    log.markSynced(ids);
    expect(log.unsyncedCount, 0);
  });

  test('ordering is oldest first so a replay is chronological', () {
    for (final e in ['a', 'b', 'c']) {
      log.record('sara', e);
    }
    expect(log.unsynced().map((e) => e['event']), ['a', 'b', 'c']);
  });

  test('distinct actors are listed alphabetically for the filter', () {
    log.record('sara', 'x');
    log.record('omar', 'y');
    log.record('sara', 'z');
    expect(log.actors(), ['omar', 'sara']);
  });

  test('combining actor, event and date narrows the rows', () {
    // Stamp two days apart by injecting the clock each entry is written with.
    final day1 = AuditLog(db, now: () => DateTime.utc(2026, 8, 10, 12));
    final day2 = AuditLog(db, now: () => DateTime.utc(2026, 8, 12, 12));
    day1.record('sara', 'line.voided', detail: 'burger');
    day1.record('omar', 'line.voided', detail: 'fries');
    day2.record('sara', 'line.voided', detail: 'salad');
    day2.record('sara', 'order.paid', detail: 'order-9');

    // Actor + event + a window that only covers day 2 leaves the single
    // matching row.
    final rows = log.recent(
      actor: 'sara',
      event: 'line.voided',
      from: DateTime.utc(2026, 8, 11),
      to: DateTime.utc(2026, 8, 13),
    );
    expect(rows.length, 1);
    expect(rows.single['detail'], 'salad');
  });
}
