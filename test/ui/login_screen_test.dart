import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/auth/auth_service.dart';
import 'package:offline_pos/core/auth/pin_hasher.dart';
import 'package:offline_pos/core/auth/pin_policy.dart';
import 'package:offline_pos/core/auth/user_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/features/auth/login_screen.dart';

import '../db/sqlite_loader.dart';
import 'fake_pin_hasher.dart';

void main() {
  late Db db;
  late AuthService auth;
  late UserStore users;
  Cashier? signedIn;
  final PinHasher hasher = FakePinHasher();

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    users = UserStore(db);
    signedIn = null;
    auth = AuthService(
      users: users, hasher: hasher, audit: AuditLog(db),
      policy: const PinPolicy(maxAttempts: 3),
    );
    await auth.enrol(id: 'sara', name: 'Sara', pin: '1234');
  });
  tearDown(() => db.close());

  Widget app() => MaterialApp(
        home: LoginScreen(
          auth: auth, users: users,
          onSignedIn: (c) => signedIn = c,
        ),
      );

  Future<void> enter(WidgetTester t, String pin) async {
    for (final d in pin.split('')) {
      await t.tap(find.byKey(Key('key-$d')));
      await t.pump();
    }
    await t.tap(find.byKey(const Key('pin-ok')));
    // The KDF resolves off the frame pipeline, so pumpAndSettle alone can return
    // before the result lands. Give the microtask queue real time to drain.
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 50));
      if (signedIn != null) break;
    }
    await t.pumpAndSettle();
  }

  testWidgets('lists the cashiers held on the device', (t) async {
    await t.pumpWidget(app());
    expect(find.byKey(const Key('user-sara')), findsOneWidget);
  });

  testWidgets('the keypad is inert until a cashier is picked', (t) async {
    await t.pumpWidget(app());
    final key = t.widget<OutlinedButton>(find.byKey(const Key('key-1')));
    expect(key.onPressed, isNull);
  });

  testWidgets('the right PIN signs in with no network', (t) async {
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('user-sara')));
    await t.pump();
    await enter(t, '1234');
    expect(signedIn?.name, 'Sara');
  });

  testWidgets('a wrong PIN says so and clears the entry', (t) async {
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('user-sara')));
    await t.pump();
    await enter(t, '9999');
    expect(find.text('Incorrect PIN'), findsOneWidget);
    expect(signedIn, isNull);
    expect(find.byKey(const Key('pin-dots')), findsOneWidget);
  });

  testWidgets('a short PIN is called malformed, not incorrect', (t) async {
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('user-sara')));
    await t.pump();
    await enter(t, '12');
    expect(find.textContaining('4 to 6 digits'), findsOneWidget);
  });

  testWidgets('a lockout says it is a lockout, not a wrong PIN', (t) async {
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('user-sara')));
    await t.pump();
    for (var i = 0; i < 3; i++) {
      await enter(t, '0000');
    }
    await enter(t, '1234');
    expect(find.textContaining('Too many attempts'), findsOneWidget);
    expect(signedIn, isNull);
  });

  testWidgets('backspace removes a digit', (t) async {
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('user-sara')));
    await t.pump();
    await t.tap(find.byKey(const Key('key-1')));
    await t.pump();
    await t.tap(find.byKey(const Key('key-2')));
    await t.pump();
    await t.tap(find.byKey(const Key('key-⌫')));
    await t.pump();
    expect(t.widget<Text>(find.byKey(const Key('pin-dots'))).data, '•');
  });

  testWidgets('a small roster stays as quick-tap chips', (t) async {
    await t.pumpWidget(app());
    // One cashier enrolled: chips, no search field.
    expect(find.byKey(const Key('user-sara')), findsOneWidget);
    expect(find.byKey(const Key('account-search')), findsNothing);
  });

  testWidgets('a large roster switches to a searchable account field', (t) async {
    // Seven accounts pushes past the chip limit, so the field appears instead.
    for (var i = 0; i < 7; i++) {
      await auth.enrol(id: 'staff-$i', name: 'Staff $i', pin: '1234');
    }
    await t.pumpWidget(app());
    await t.pumpAndSettle();

    expect(find.byKey(const Key('account-search')), findsOneWidget);
    expect(find.byKey(const Key('user-sara')), findsNothing);

    // Type a name, pick it from the options, and the keypad unlocks for that person.
    await t.enterText(find.byKey(const Key('account-search')), 'Staff 3');
    await t.pumpAndSettle();
    await t.tap(find.text('Staff 3').last);
    await t.pumpAndSettle();

    expect(find.byKey(const Key('signing-in-as')), findsOneWidget);
    await enter(t, '1234');
    expect(signedIn?.id, 'staff-3');
  });

  testWidgets('a device with no cashiers says so instead of hanging', (t) async {
    final empty = Db.open(':memory:');
    await t.pumpWidget(MaterialApp(
      home: LoginScreen(
        auth: AuthService(
            users: UserStore(empty), hasher: hasher, audit: AuditLog(empty)),
        users: UserStore(empty),
        onSignedIn: (_) {},
      ),
    ));
    expect(find.byKey(const Key('no-users')), findsOneWidget);
    empty.close();
  });
}
