import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/auth/auth_service.dart';
import 'package:offline_pos/core/auth/legacy_pin.dart';
import 'package:offline_pos/core/auth/pin_hasher.dart';
import 'package:offline_pos/core/auth/user_store.dart';
import 'package:offline_pos/core/db/database.dart';

import '../db/sqlite_loader.dart';

/// What Dishflow writes for [pin]: SHA-256 over the salt's bytes then the PIN's.
String dishflowHash(String pin, String saltHex) {
  final salt = [
    for (var i = 0; i < saltHex.length; i += 2)
      int.parse(saltHex.substring(i, i + 2), radix: 16),
  ];
  return sha256.convert([...salt, ...utf8.encode(pin)]).toString();
}

void main() {
  const salt = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';

  group('LegacyPin', () {
    final stored = LegacyPin.wrap(dishflowHash('4821', salt));

    test('accepts the PIN Dishflow hashed', () {
      expect(LegacyPin.verify('4821', salt, stored), isTrue);
    });

    test('rejects any other PIN', () {
      expect(LegacyPin.verify('4822', salt, stored), isFalse);
      expect(LegacyPin.verify('', salt, stored), isFalse);
    });

    test('rejects the right PIN against another salt', () {
      expect(LegacyPin.verify('4821', 'ffffffffffffffffffffffffffffffff', stored),
          isFalse);
    });

    test('a salt or hash it cannot read is a mismatch, not a crash', () {
      expect(LegacyPin.verify('4821', 'not-hex', stored), isFalse);
      expect(LegacyPin.verify('4821', salt, 'something-else'), isFalse);
      expect(LegacyPin.isUsable('abc', salt), isFalse);
      expect(LegacyPin.isUsable(dishflowHash('1', salt), ''), isFalse);
      expect(LegacyPin.isUsable(dishflowHash('1', salt), salt), isTrue);
    });

    test("is told apart from the till's own hash by its prefix", () {
      expect(LegacyPin.isLegacy(stored), isTrue);
      expect(LegacyPin.isLegacy('c29tZSBhcmdvbjIgaGFzaA=='), isFalse);
    });
  });

  group('an account imported from Dishflow', () {
    late Db db;
    late UserStore users;
    late AuditLog audit;
    late AuthService auth;
    final hasher = Argon2idPinHasher(memory: 1024, iterations: 1);

    Cashier imported({String role = 'cashier', String? hash}) => Cashier(
          id: 'dishflow-7',
          name: 'Rashad',
          role: role,
          pinSalt: salt,
          pinHash: hash ?? LegacyPin.wrap(dishflowHash('4821', salt)),
        );

    setUpAll(useSystemSqlite);
    setUp(() {
      db = Db.open(':memory:');
      users = UserStore(db);
      audit = AuditLog(db);
      auth = AuthService(users: users, hasher: hasher, audit: audit);
    });
    tearDown(() => db.close());

    test('signs in with the PIN it had in Dishflow', () async {
      users.upsert(imported());
      expect(await auth.unlock('dishflow-7', '4821'), isA<AuthOk>());
    });

    test("is re-hashed the till's own way on that first sign-in", () async {
      users.upsert(imported());
      await auth.unlock('dishflow-7', '4821');

      final after = users.byId('dishflow-7')!;
      expect(LegacyPin.isLegacy(after.pinHash), isFalse);
      expect(after.pinSalt, isNot(salt));
      expect(await hasher.verify('4821', after.pinSalt, after.pinHash), isTrue);
      expect(auth.signedIn!.pinHash, after.pinHash);
    });

    test('still signs in afterwards, and only with the same PIN', () async {
      users.upsert(imported());
      await auth.unlock('dishflow-7', '4821');
      auth.signOut();
      expect(await auth.unlock('dishflow-7', '4821'), isA<AuthOk>());
      auth.signOut();
      expect(await auth.unlock('dishflow-7', '0000'), isA<AuthRejected>());
    });

    test('a wrong PIN is rejected and leaves the account as imported', () async {
      users.upsert(imported());
      expect(await auth.unlock('dishflow-7', '1111'), isA<AuthRejected>());
      expect(LegacyPin.isLegacy(users.byId('dishflow-7')!.pinHash), isTrue);
      expect(auth.failuresFor('dishflow-7'), 1);
    });

    test('an imported manager can approve, and is upgraded by doing so',
        () async {
      users.upsert(imported(role: 'manager'));
      final approved = await auth.authorizeManager('4821');
      expect(approved?.id, 'dishflow-7');
      expect(LegacyPin.isLegacy(users.byId('dishflow-7')!.pinHash), isFalse);
    });

    test('an account Dishflow held no PIN for matches nothing', () async {
      users.upsert(const Cashier(
          id: 'dishflow-8', name: 'Kajoo', pinSalt: '', pinHash: ''));
      expect(await auth.unlock('dishflow-8', '1234'), isA<AuthRejected>());
      expect(await auth.authorizeCashier('dishflow-8', '1234'), isFalse);
    });
  });
}
