import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/attendance_store.dart';
import 'package:offline_pos/core/db/database.dart';

import 'sqlite_loader.dart';

void main() {
  late Db db;
  late AttendanceStore attendance;
  var clock = DateTime.utc(2026, 8, 12, 9, 0);

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    clock = DateTime.utc(2026, 8, 12, 9, 0);
    attendance = AttendanceStore(db, now: () => clock);
  });
  tearDown(() => db.close());

  test('clocking in opens an entry and marks the staff on the clock', () {
    attendance.clockIn('sara');
    expect(attendance.isClockedIn('sara'), isTrue);
    expect(attendance.onNow().single.staffId, 'sara');
  });

  test('a second clock-in while already on the clock does not open a duplicate', () {
    final first = attendance.clockIn('sara');
    final second = attendance.clockIn('sara');
    expect(second.id, first.id);
    expect(attendance.onNow(), hasLength(1));
  });

  test('clocking out closes the entry and records the worked time', () {
    attendance.clockIn('sara');
    clock = clock.add(const Duration(hours: 2, minutes: 30));
    attendance.clockOut('sara');
    expect(attendance.isClockedIn('sara'), isFalse);
    final entry = attendance.recent().single;
    expect(entry.isOpen, isFalse);
    expect(entry.worked(clock), const Duration(hours: 2, minutes: 30));
  });

  test('clocking out when not on the clock is a no-op', () {
    attendance.clockOut('nobody');
    expect(attendance.recent(), isEmpty);
  });

  test('several staff can be on the clock against one till', () {
    attendance.clockIn('sara');
    attendance.clockIn('omar');
    expect(attendance.onNow().map((e) => e.staffId).toSet(), {'sara', 'omar'});
  });
}
