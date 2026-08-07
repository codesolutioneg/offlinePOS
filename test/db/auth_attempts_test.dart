import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/auth/pin_policy.dart';
import 'package:offline_pos/core/db/attempt_store.dart';
import 'package:offline_pos/core/db/database.dart';

import 'sqlite_loader.dart';

void main() {
  late Db db;
  const policy = PinPolicy();

  setUpAll(useSystemSqlite);
  setUp(() => db = Db.open(':memory:'));
  tearDown(() => db.close());

  /// A guard built the way a relaunch builds one: fresh object, same table.
  PinAttemptGuard relaunch() => PinAttemptGuard(policy, store: SqliteAttemptStore(db));

  test('a lockout survives the app being force-quit', () {
    final now = DateTime(2026, 1, 1, 12);
    final guard = relaunch();
    for (var i = 0; i < policy.maxAttempts; i++) {
      guard.recordFailure('sara', now: now);
    }
    expect(guard.isLocked('sara', now: now), isTrue);

    // Killing the app between guesses used to reset the count, which turns a
    // 4-digit PIN into ten thousand free tries for whoever has the till.
    expect(relaunch().isLocked('sara', now: now), isTrue);
    expect(relaunch().failures('sara'), policy.maxAttempts);
  });

  test('each further failure past the limit costs longer than the last', () {
    final now = DateTime(2026, 1, 1, 12);
    final guard = relaunch();
    for (var i = 0; i < policy.maxAttempts; i++) {
      guard.recordFailure('sara', now: now);
    }
    final first = guard.lockedUntil('sara')!;

    guard.recordFailure('sara', now: now);
    final second = guard.lockedUntil('sara')!;

    // A flat window is a rate limit, not a deterrent: an attacker waits it out
    // and keeps going at a fixed cost per batch.
    expect(second.isAfter(first), isTrue);
    expect(second.difference(now), policy.lockout * 2);
  });

  test('the backoff stops growing rather than locking a shift out', () {
    final now = DateTime(2026, 1, 1, 12);
    final guard = relaunch();
    for (var i = 0; i < 40; i++) {
      guard.recordFailure('sara', now: now);
    }
    expect(guard.lockedUntil('sara')!.difference(now), policy.maxLockout);
  });

  test('signing in clears the record for good', () {
    final guard = relaunch();
    guard.recordFailure('sara');
    guard.recordSuccess('sara');
    expect(relaunch().failures('sara'), 0);
    expect(relaunch().isLocked('sara'), isFalse);
  });

  test('the lockout is per cashier, so one person cannot shut the till', () {
    final now = DateTime(2026, 1, 1, 12);
    final guard = relaunch();
    for (var i = 0; i < policy.maxAttempts; i++) {
      guard.recordFailure('sara', now: now);
    }
    expect(relaunch().isLocked('omar', now: now), isFalse);
  });
}
