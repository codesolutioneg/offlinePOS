import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/auth/totp.dart';

/// RFC 6238 says exactly what these codes must be, so the vectors from its
/// appendix are the test: an implementation that agrees with them agrees with every
/// authenticator app a manager might have on their phone.
void main() {
  // The RFC's SHA-1 test key is the ASCII "12345678901234567890"; base32 of that.
  const rfcSecret = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';

  DateTime atEpoch(int seconds) =>
      DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);

  test('the RFC 6238 vectors produce the RFC 6238 codes', () {
    expect(Totp.codeAt(rfcSecret, atEpoch(59)), '287082');
    expect(Totp.codeAt(rfcSecret, atEpoch(1111111109)), '081804');
    expect(Totp.codeAt(rfcSecret, atEpoch(1111111111)), '050471');
    expect(Totp.codeAt(rfcSecret, atEpoch(1234567890)), '005924');
    expect(Totp.codeAt(rfcSecret, atEpoch(2000000000)), '279037');
  });

  test('the code of the moment verifies', () {
    final now = atEpoch(1234567890);
    expect(Totp.verify(rfcSecret, Totp.codeAt(rfcSecret, now), at: now), isTrue);
  });

  test('one step of clock drift either way is still accepted', () {
    final now = atEpoch(1234567890);
    for (final offset in const [-30, 30]) {
      final theirs = Totp.codeAt(rfcSecret, now.add(Duration(seconds: offset)));
      expect(Totp.verify(rfcSecret, theirs, at: now), isTrue,
          reason: 'a phone $offset s out must still approve');
    }
  });

  test('a code two steps old is refused', () {
    final now = atEpoch(1234567890);
    final stale = Totp.codeAt(rfcSecret, now.subtract(const Duration(seconds: 90)));
    expect(Totp.verify(rfcSecret, stale, at: now), isFalse);
  });

  test('a wrong, blank or short code is refused', () {
    final now = atEpoch(1234567890);
    expect(Totp.verify(rfcSecret, '000000', at: now), isFalse);
    expect(Totp.verify(rfcSecret, '', at: now), isFalse);
    expect(Totp.verify(rfcSecret, '5924', at: now), isFalse);
  });

  test('a secret that is not usable never verifies anything', () {
    final now = atEpoch(1234567890);
    // An empty secret is what a user with no second factor has; it must not become
    // a skeleton key by matching whatever is typed.
    expect(Totp.verify('', '000000', at: now), isFalse);
    expect(Totp.verify('', '', at: now), isFalse);
    expect(Totp.verify('not base32 at all!!!', '123456', at: now), isFalse);
  });

  test('a secret is read the way an app prints it', () {
    // Spaces, lower case and padding all come off a phone screen.
    expect(Totp.normaliseSecret('gezd gnbv gy3t qojq gezd gnbv gy3t qojq==='),
        rfcSecret);
    // Too short to be a real secret, so it is refused rather than half-accepted.
    expect(Totp.normaliseSecret('GEZDGNBV'), isNull);
    expect(Totp.normaliseSecret(''), isNull);
  });

  test('the same secret, however it was typed, gives the same code', () {
    final now = atEpoch(1234567890);
    expect(Totp.codeAt('gezd gnbv gy3t qojq gezd gnbv gy3t qojq', now),
        Totp.codeAt(rfcSecret, now));
  });
}
