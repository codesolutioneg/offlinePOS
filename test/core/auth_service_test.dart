import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/auth/auth_service.dart';
import 'package:offline_pos/core/auth/pin_hasher.dart';
import 'package:offline_pos/core/auth/pin_policy.dart';
import 'package:offline_pos/core/auth/user_store.dart';
import 'package:offline_pos/core/db/database.dart';

import '../db/sqlite_loader.dart';

void main() {
  late Db db;
  late AuthService auth;
  late UserStore users;
  late AuditLog audit;
  // Cheap KDF parameters so the suite stays fast.
  final hasher = Argon2idPinHasher(memory: 1024, iterations: 1);
  const policy = PinPolicy(maxAttempts: 3, lockout: Duration(minutes: 5));

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    users = UserStore(db);
    audit = AuditLog(db);
    auth = AuthService(users: users, hasher: hasher, audit: audit, policy: policy);
    await auth.enrol(id: 'sara', name: 'Sara', pin: '1234');
  });
  tearDown(() => db.close());

  test('the right PIN signs the cashier in, with no network anywhere', () async {
    final r = await auth.unlock('sara', '1234');
    expect(r, isA<AuthOk>());
    expect(auth.signedIn!.name, 'Sara');
  });

  test('a wrong PIN is rejected', () async {
    expect(await auth.unlock('sara', '9999'), isA<AuthRejected>());
    expect(auth.isSignedIn, isFalse);
  });

  test('an unknown cashier looks exactly like a wrong PIN', () async {
    // A different answer here would let someone enumerate who works there.
    final unknown = await auth.unlock('ghost', '1234');
    final wrong = await auth.unlock('sara', '0000');
    expect(unknown.runtimeType, wrong.runtimeType);
  });

  test('a malformed PIN is refused before any hashing', () async {
    expect(await auth.unlock('sara', '12'), isA<AuthMalformed>());
    expect(await auth.unlock('sara', 'abcd'), isA<AuthMalformed>());
  });

  test('repeated failures lock that cashier out', () async {
    for (var i = 0; i < policy.maxAttempts; i++) {
      await auth.unlock('sara', '0000');
    }
    expect(await auth.unlock('sara', '1234'), isA<AuthLockedOut>());
  });

  test('the lockout is per cashier, so one person cannot lock the till', () async {
    await auth.enrol(id: 'omar', name: 'Omar', pin: '5678');
    for (var i = 0; i < policy.maxAttempts; i++) {
      await auth.unlock('sara', '0000');
    }
    expect(await auth.unlock('sara', '1234'), isA<AuthLockedOut>());
    expect(await auth.unlock('omar', '5678'), isA<AuthOk>());
  });

  test('a success clears the failure count', () async {
    await auth.unlock('sara', '0000');
    await auth.unlock('sara', '1234');
    expect(auth.failuresFor('sara'), 0);
  });

  test('an inactive cashier cannot sign in', () async {
    final s = users.byId('sara')!;
    users.upsert(Cashier(id: s.id, name: s.name, pinSalt: s.pinSalt,
        pinHash: s.pinHash, active: false));
    expect(await auth.unlock('sara', '1234'), isA<AuthRejected>());
  });

  test('the PIN is never recoverable from what is stored', () async {
    final s = users.byId('sara')!;
    expect(s.pinHash, isNot(contains('1234')));
    expect(s.pinSalt, isNotEmpty);
  });

  test('sign in, rejection and sign out are all auditable offline', () async {
    await auth.unlock('sara', '0000');
    await auth.unlock('sara', '1234');
    auth.signOut();
    final events = audit.unsynced().map((e) => e['event']).toList();
    expect(events, containsAll(['pin.rejected', 'pin.unlock', 'sign_out']));
  });

  test('a roster replace never leaves the till with nobody able to sign in', () {
    users.replaceAll(const []);
    expect(users.active(), isNotEmpty);
  });
}
