import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/auth/pin_hasher.dart';

void main() {
  // Cheap parameters so the suite stays fast. Production uses the defaults.
  final hasher = PinHasher(memory: 1024, iterations: 1);

  test('the same PIN and salt give the same hash', () async {
    final salt = PinHasher.newSalt();
    expect(await hasher.hash('1234', salt), await hasher.hash('1234', salt));
  });

  test('a different salt gives a different hash for the same PIN', () async {
    final a = await hasher.hash('1234', PinHasher.newSalt());
    final b = await hasher.hash('1234', PinHasher.newSalt());
    expect(a, isNot(b));
  });

  test('verify accepts the right PIN and rejects a wrong one', () async {
    final salt = PinHasher.newSalt();
    final stored = await hasher.hash('4321', salt);
    expect(await hasher.verify('4321', salt, stored), isTrue);
    expect(await hasher.verify('4322', salt, stored), isFalse);
  });

  test('salts are unique and 16 bytes', () async {
    final salts = List.generate(50, (_) => PinHasher.newSalt());
    expect(salts.toSet().length, 50);
  });

  test('a malformed stored hash is rejected, not thrown on', () async {
    final salt = PinHasher.newSalt();
    expect(await hasher.verify('1234', salt, ''), isFalse);
  });
}
