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
}
