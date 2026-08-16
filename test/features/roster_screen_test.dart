import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/auth/auth_service.dart';
import 'package:offline_pos/core/auth/pin_hasher.dart';
import 'package:offline_pos/core/auth/user_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/features/admin/roster_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

void main() {
  late Db db;
  late AuthService auth;
  late UserStore users;
  final PinHasher hasher = FakePinHasher();
  int changedCount = 0;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    users = UserStore(db);
    changedCount = 0;
    auth = AuthService(users: users, hasher: hasher, audit: AuditLog(db));
    await auth.enrol(id: 'sara', name: 'Sara', pin: '1234');
  });
  tearDown(() => db.close());

  Widget app({bool canAssignManager = true}) => MaterialApp(
        home: RosterScreen(
          users: users,
          auth: auth,
          onChanged: () => changedCount++,
          canAssignManager: canAssignManager,
        ),
      );

  testWidgets('lists the existing staff on the device', (t) async {
    await t.pumpWidget(app());
    expect(find.byKey(const Key('staff-sara')), findsOneWidget);
    expect(find.text('Sara'), findsOneWidget);
  });

  testWidgets('the add-staff control is present', (t) async {
    await t.pumpWidget(app());
    expect(find.byKey(const Key('add-staff')), findsOneWidget);
  });

  testWidgets('adding a cashier with a valid PIN enrols them and shows up in the list',
      (t) async {
    await t.pumpWidget(app());

    await t.tap(find.byKey(const Key('add-staff')));
    await t.pumpAndSettle();

    await t.enterText(find.byKey(const Key('staff-name')), 'Omar');
    await t.enterText(find.byKey(const Key('staff-pin')), '5678');
    await t.tap(find.byKey(const Key('staff-form-save')));
    await t.pumpAndSettle();

    final added = users.active().where((c) => c.name == 'Omar');
    expect(added, isNotEmpty);
    expect(find.text('Omar'), findsOneWidget);
    expect(changedCount, 1);
  });

  testWidgets('a PIN outside 4 to 6 digits is rejected inline, not enrolled', (t) async {
    await t.pumpWidget(app());

    await t.tap(find.byKey(const Key('add-staff')));
    await t.pumpAndSettle();

    await t.enterText(find.byKey(const Key('staff-name')), 'Lina');
    await t.enterText(find.byKey(const Key('staff-pin')), '12');
    await t.tap(find.byKey(const Key('staff-form-save')));
    await t.pump();

    expect(find.byKey(const Key('staff-form-error')), findsOneWidget);
    expect(users.active().where((c) => c.name == 'Lina'), isEmpty);
    expect(changedCount, 0);
  });

  testWidgets('deactivating a cashier removes them from the active roster', (t) async {
    await t.pumpWidget(app());
    // Actions now live in an overflow menu, so open it before tapping Deactivate.
    await t.tap(find.byKey(const Key('staff-menu-sara')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('deactivate-sara')));
    await t.pumpAndSettle();

    expect(users.byId('sara')!.active, isFalse);
    expect(find.byKey(const Key('staff-sara')), findsNothing);
    expect(changedCount, 1);
  });

  testWidgets('without manager rights the manager role cannot be chosen', (t) async {
    await t.pumpWidget(app(canAssignManager: false));

    await t.tap(find.byKey(const Key('add-staff')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('staff-role')));
    await t.pumpAndSettle();

    // The dropdown offers Cashier only; Manager is not an option.
    expect(find.text('Manager'), findsNothing);
    expect(find.text('Cashier'), findsWidgets);
  });

  testWidgets('without manager rights a new staff member is never enrolled as manager', (t) async {
    await t.pumpWidget(app(canAssignManager: false));

    await t.tap(find.byKey(const Key('add-staff')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('staff-name')), 'Omar');
    await t.enterText(find.byKey(const Key('staff-pin')), '4321');
    await t.tap(find.byKey(const Key('staff-form-save')));
    await t.pumpAndSettle();

    final omar = users.active().firstWhere((c) => c.name == 'Omar');
    expect(omar.isManager, isFalse);
  });

  testWidgets('without manager rights an existing manager row is locked, not editable', (t) async {
    await auth.enrol(id: 'boss', name: 'Boss', pin: '9999', role: 'manager');
    await t.pumpWidget(app(canAssignManager: false));

    // The manager row shows a lock and exposes no action menu to reset the PIN.
    expect(find.byKey(const Key('staff-boss')), findsOneWidget);
    expect(find.byKey(const Key('staff-menu-boss')), findsNothing);
    // A plain cashier stays fully editable.
    expect(find.byKey(const Key('staff-menu-sara')), findsOneWidget);
  });

  testWidgets('a manager can enrol an authenticator and take it off again',
      (t) async {
    await auth.enrol(id: 'boss', name: 'Boss', pin: '9999', role: 'manager');
    await t.pumpWidget(app());

    await t.tap(find.byKey(const Key('staff-menu-boss')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('totp-boss')));
    await t.pumpAndSettle();

    // A half-typed secret cannot be saved, and says why rather than failing later
    // when a manager cannot approve a void.
    await t.enterText(find.byKey(const Key('totp-secret')), 'GEZD');
    await t.pumpAndSettle();
    expect(t.widget<FilledButton>(find.byKey(const Key('totp-save'))).onPressed,
        isNull);

    await t.enterText(find.byKey(const Key('totp-secret')),
        'gezd gnbv gy3t qojq gezd gnbv gy3t qojq');
    await t.pumpAndSettle();
    // The code is echoed back so the phone and the till can be proven to agree.
    expect(find.byKey(const Key('totp-preview')), findsOneWidget);
    await t.tap(find.byKey(const Key('totp-save')));
    await t.pumpAndSettle();

    expect(users.byId('boss')!.totpSecret, 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ');
    expect(find.textContaining('authenticator on'), findsOneWidget);

    await t.tap(find.byKey(const Key('staff-menu-boss')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('totp-boss')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('totp-off')));
    await t.pumpAndSettle();

    expect(users.byId('boss')!.totpSecret, isNull);
  });

  testWidgets('a name change keeps the authenticator that guards the account',
      (t) async {
    await auth.enrol(id: 'boss', name: 'Boss', pin: '9999', role: 'manager');
    users.setTotpSecret('boss', 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ');
    await t.pumpWidget(app());

    await t.tap(find.byKey(const Key('staff-menu-boss')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('edit-boss')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('staff-name')), 'Boss Lady');
    await t.tap(find.byKey(const Key('staff-form-save')));
    await t.pumpAndSettle();

    expect(users.byId('boss')!.hasSecondFactor, isTrue);
  });
}
