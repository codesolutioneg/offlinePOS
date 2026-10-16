import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/auth/auth_service.dart';
import 'package:offline_pos/core/auth/user_store.dart';
import 'package:offline_pos/core/db/attendance_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/features/admin/clock_dialog.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

/// The floor's Empl button: a card of everyone, and a tap on a name clocks that
/// person in or out.
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
    await auth.enrol(id: 'omar', name: 'Omar', pin: '4321');
  });
  tearDown(() => db.close());

  Future<void> open(WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            key: const Key('open'),
            onPressed: () => showClockDialog(context,
                users: users, attendance: attendance, auth: auth),
            child: const Text('Empl'),
          ),
        ),
      ),
    ));
    await t.tap(find.byKey(const Key('open')));
    await t.pumpAndSettle();
  }

  Future<void> enterPin(WidgetTester t, String pin) async {
    for (final d in pin.split('')) {
      await t.tap(find.byKey(Key('key-$d')).last);
      await t.pump();
    }
    await t.tap(find.byKey(const Key('attend-pin-ok')));
    await t.pumpAndSettle();
  }

  testWidgets('every employee is on the card', (t) async {
    await open(t);
    expect(find.byKey(const Key('clock-dialog')), findsOneWidget);
    expect(find.byKey(const Key('clock-staff-sara')), findsOneWidget);
    expect(find.byKey(const Key('clock-staff-omar')), findsOneWidget);
  });

  testWidgets('a tap and their PIN clocks them in, and the card stays up',
      (t) async {
    await open(t);
    await t.tap(find.byKey(const Key('clock-staff-sara')));
    await t.pumpAndSettle();
    await enterPin(t, '1234');

    expect(attendance.isClockedIn('sara'), isTrue);
    expect(find.byKey(const Key('clock-dialog')), findsOneWidget,
        reason: 'the next person clocks in from the same card');
    expect(find.textContaining('Since'), findsOneWidget);
  });

  testWidgets('a tap on someone on the clock clocks them out', (t) async {
    attendance.clockIn('omar');
    await open(t);
    await t.tap(find.byKey(const Key('clock-staff-omar')));
    await t.pumpAndSettle();
    await enterPin(t, '4321');

    expect(attendance.isClockedIn('omar'), isFalse);
  });

  testWidgets('someone else\'s PIN clocks nobody in', (t) async {
    await open(t);
    await t.tap(find.byKey(const Key('clock-staff-sara')));
    await t.pumpAndSettle();
    await enterPin(t, '4321');

    expect(attendance.isClockedIn('sara'), isFalse);
  });
}
