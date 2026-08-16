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

  group('reading the hours back', () {
    /// One finished shift for [who], starting [at] and lasting [hours].
    void shift(String who, DateTime at, double hours) {
      clock = at;
      attendance.clockIn(who);
      clock = at.add(Duration(minutes: (hours * 60).round()));
      attendance.clockOut(who);
    }

    test('a window takes the shifts that started inside it, oldest first', () {
      shift('sara', DateTime.utc(2026, 8, 10, 9), 4);
      shift('omar', DateTime.utc(2026, 8, 11, 9), 5);
      shift('sara', DateTime.utc(2026, 8, 12, 9), 6);

      final week = attendance.between(
          from: DateTime.utc(2026, 8, 11), to: DateTime.utc(2026, 8, 13));
      expect(week.map((e) => e.staffId).toList(), ['omar', 'sara']);
      // The end is exclusive, so a day range cannot pick up tomorrow's opener.
      expect(
          attendance.between(
              from: DateTime.utc(2026, 8, 11), to: DateTime.utc(2026, 8, 12)),
          hasLength(1));
    });

    test('an unbounded read is everything, and one staff member can be picked out',
        () {
      shift('sara', DateTime.utc(2026, 8, 10, 9), 4);
      shift('omar', DateTime.utc(2026, 8, 11, 9), 5);

      expect(attendance.between(), hasLength(2));
      expect(attendance.between(staffId: 'sara').single.worked(clock),
          const Duration(hours: 4));
    });

    test('a shift still running is read back, and counts up to now', () {
      clock = DateTime.utc(2026, 8, 12, 9);
      attendance.clockIn('sara');
      final open = attendance.between().single;
      expect(open.isOpen, isTrue);
      expect(open.worked(DateTime.utc(2026, 8, 12, 12)), const Duration(hours: 3));
    });
  });
}
