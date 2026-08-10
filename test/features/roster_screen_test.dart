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

  Widget app() => MaterialApp(
        home: RosterScreen(
          users: users,
          auth: auth,
          onChanged: () => changedCount++,
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
    await t.tap(find.byKey(const Key('deactivate-sara')));
    await t.pumpAndSettle();

    expect(users.byId('sara')!.active, isFalse);
    expect(find.byKey(const Key('staff-sara')), findsNothing);
    expect(changedCount, 1);
  });
}
