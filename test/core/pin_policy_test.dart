import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/auth/pin_policy.dart';

void main() {
  const policy = PinPolicy();

  test('rejects malformed PINs', () {
    expect(policy.isWellFormed('123'), isFalse);
    expect(policy.isWellFormed('1234567'), isFalse);
    expect(policy.isWellFormed('12a4'), isFalse);
    expect(policy.isWellFormed('1234'), isTrue);
  });

  test('locks out after the attempt limit', () {
    final guard = PinAttemptGuard(policy);
    final now = DateTime(2026, 1, 1, 12);
    for (var i = 0; i < policy.maxAttempts; i++) {
      expect(guard.isLocked('c1', now: now), isFalse);
      guard.recordFailure('c1', now: now);
    }
    expect(guard.isLocked('c1', now: now), isTrue);
  });

  test('the lockout expires', () {
    final guard = PinAttemptGuard(policy);
    final now = DateTime(2026, 1, 1, 12);
    for (var i = 0; i < policy.maxAttempts; i++) {
      guard.recordFailure('c1', now: now);
    }
    expect(guard.isLocked('c1', now: now.add(policy.lockout).add(const Duration(seconds: 1))), isFalse);
  });

  test('a success clears the counter', () {
    final guard = PinAttemptGuard(policy);
    guard.recordFailure('c1');
    guard.recordSuccess('c1');
    expect(guard.failures('c1'), 0);
  });
}
