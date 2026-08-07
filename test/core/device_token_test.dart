import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/auth/device_token.dart';

DeviceToken token(DateTime issued, Duration life) => DeviceToken(
      deviceId: 'till-1', tenantId: 't1',
      issuedAt: issued, expiresAt: issued.add(life), signature: 'sig');

void main() {
  final issued = DateTime(2026, 1, 1);

  test('a long grace period keeps the till selling through an outage', () {
    final t = token(issued, const Duration(days: 30));
    // Three weeks with no contact and the till still works.
    expect(t.isValidAt(issued.add(const Duration(days: 21))), isTrue);
  });

  test('renewal starts well before expiry', () {
    final t = token(issued, const Duration(days: 30));
    expect(t.shouldRenewAt(issued.add(const Duration(days: 10))), isFalse);
    expect(t.shouldRenewAt(issued.add(const Duration(days: 25))), isTrue);
  });

  test('expiry is a hard stop', () {
    final t = token(issued, const Duration(days: 30));
    final after = issued.add(const Duration(days: 31));
    expect(t.isValidAt(after), isFalse);
    expect(t.remainingAt(after), Duration.zero);
  });

  test('survives a serialise/restore cycle', () {
    final t = token(issued, const Duration(days: 30));
    final again = DeviceToken.fromMap(t.toMap());
    expect(again.expiresAt, t.expiresAt);
    expect(again.deviceId, t.deviceId);
  });
}
