import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/auth/auth_service.dart';
import 'package:offline_pos/core/auth/user_store.dart';
import 'package:offline_pos/core/db/attendance_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/features/admin/attendance_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

void main() {
  late Db db;
  late UserStore users;
  late AttendanceStore attendance;
  late AuthService auth;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    users = UserStore(db);
    attendance = AttendanceStore(db);
    auth = AuthService(users: users, hasher: FakePinHasher(), audit: AuditLog(db));
    await auth.enrol(id: 'sara', name: 'Sara', pin: '1234');
  });
  tearDown(() => db.close());

  Widget app() => MaterialApp(
        home: AttendanceScreen(users: users, attendance: attendance, auth: auth),
      );

  Future<void> enterPin(WidgetTester t, String pin) async {
    expect(find.byKey(const Key('attend-pin')), findsOneWidget);
    for (final d in pin.split('')) {
      await t.tap(find.byKey(Key('key-$d')).last);
      await t.pump();
    }
    await t.tap(find.byKey(const Key('attend-pin-ok')));
    await t.pumpAndSettle();
  }

  testWidgets('lists staff with a clock-in control when off the clock', (t) async {
    await t.pumpWidget(app());
    expect(find.text('Sara'), findsOneWidget);
    expect(find.byKey(const Key('clock-in-sara')), findsOneWidget);
  });

  testWidgets('clocking in asks for PIN then flips the row', (t) async {
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('clock-in-sara')));
    await t.pumpAndSettle();
    await enterPin(t, '1234');
    expect(attendance.isClockedIn('sara'), isTrue);
    expect(find.byKey(const Key('clock-out-sara')), findsOneWidget);
  });

  testWidgets('a wrong clock-in PIN leaves them off the clock', (t) async {
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('clock-in-sara')));
    await t.pumpAndSettle();
    await enterPin(t, '9999');
    expect(attendance.isClockedIn('sara'), isFalse);
    expect(find.byKey(const Key('clock-in-sara')), findsOneWidget);
  });

  testWidgets('clocking out asks for PIN then returns off the clock', (t) async {
    attendance.clockIn('sara');
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('clock-out-sara')));
    await t.pumpAndSettle();
    await enterPin(t, '1234');
    expect(attendance.isClockedIn('sara'), isFalse);
    expect(find.byKey(const Key('clock-in-sara')), findsOneWidget);
  });
}
