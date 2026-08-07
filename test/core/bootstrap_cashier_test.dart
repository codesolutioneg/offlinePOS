import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/auth/auth_service.dart';
import 'package:offline_pos/core/auth/bootstrap_cashier.dart';
import 'package:offline_pos/core/auth/user_store.dart';
import 'package:offline_pos/core/db/database.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

void main() {
  late Db db;
  late UserStore users;
  late AuthService auth;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    users = UserStore(db);
    auth = AuthService(
      users: users,
      hasher: FakePinHasher(),
      audit: AuditLog(db),
    );
  });
  tearDown(() => db.close());

  test('a fresh till gets a code that is not the same on every till', () async {
    final mine = await BootstrapCashier.ensure(auth, users);
    expect(mine, isNotNull);
    expect(mine, matches(RegExp(r'^\d{6}$')));

    // The literal '1234' this replaced was in the source, therefore in the
    // binary, therefore identical everywhere and recoverable by anyone who runs
    // reFlutter over the app. Two tills must not share a credential.
    final theirs = {for (var i = 0; i < 20; i++) BootstrapCashier.newPin()};
    expect(theirs.length, greaterThan(15));
  });

  test('the code works, and it is the only way in until staff are enrolled',
      () async {
    final pin = (await BootstrapCashier.ensure(auth, users))!;
    expect(await auth.unlock(BootstrapCashier.id, pin), isA<AuthOk>());
    expect(users.active().single.id, BootstrapCashier.id);
  });

  test('a relaunch issues a new code rather than reusing a stored one', () async {
    final first = await BootstrapCashier.ensure(auth, users);
    final second = await BootstrapCashier.ensure(auth, users);

    expect(second, isNot(first));
    // Nothing anywhere holds a PIN in the clear, so the only way to show one
    // again is to make a new one. The old one stops working immediately.
    expect(await auth.unlock(BootstrapCashier.id, first!), isA<AuthRejected>());
    expect(await auth.unlock(BootstrapCashier.id, second!), isA<AuthOk>());
  });

  test('a till with a real roster is never given a provisioning code', () async {
    await auth.enrol(id: 'sara', name: 'Sara', pin: '4821');
    expect(await BootstrapCashier.ensure(auth, users), isNull);
  });

  test('the provisioning account alongside real staff is left alone', () async {
    await BootstrapCashier.ensure(auth, users);
    await auth.enrol(id: 'sara', name: 'Sara', pin: '4821');

    // Two accounts now, so the till is past provisioning and the notice stops.
    expect(await BootstrapCashier.ensure(auth, users), isNull);
  });
}
