import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/sync/retry_arming.dart';

import '../db/sqlite_loader.dart';

void main() {
  late Db db;
  late SettingsRetryArming arming;
  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    arming = SettingsRetryArming(SettingsStore(db));
  });
  tearDown(() => db.close());

  test('a till that never failed a close has nothing armed', () {
    expect(arming.read(), isNull);
  });

  test('the arming survives being written and read back', () {
    final at = DateTime.utc(2026, 1, 1, 23, 45);
    arming.write(at, 'server down at close');

    final back = arming.read();
    expect(back, isNotNull);
    expect(back!.armedAt, at, reason: 'the window runs from this instant');
    expect(back.reason, 'server down at close');
  });

  test('a local arming time comes back as utc', () {
    // Written from a local clock, compared against a utc now. Storing the local
    // wall time would move the window by the shop's offset.
    final at = DateTime(2026, 1, 1, 23, 45);
    arming.write(at, 'server down at close');
    expect(arming.read()!.armedAt, at.toUtc());
    expect(arming.read()!.armedAt.isUtc, isTrue);
  });

  test('clearing leaves nothing for the next boot to pick up', () {
    arming.write(DateTime.utc(2026, 1, 1), 'server down at close');
    arming.clear();
    expect(arming.read(), isNull);
  });

  test('an unreadable stamp is nothing armed, not a fresh window', () {
    SettingsStore(db).setString('sync_retry_armed_at', 'not a date');
    expect(arming.read(), isNull);
  });
}
