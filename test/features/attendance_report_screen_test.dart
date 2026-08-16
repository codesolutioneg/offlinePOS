import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/attendance_store.dart';
import 'package:offline_pos/features/reports/attendance_report_screen.dart';

void main() {
  AttendanceEntry entry(int id, String staffId, DateTime inAt, {DateTime? outAt}) =>
      AttendanceEntry(id: id, staffId: staffId, clockIn: inAt, clockOut: outAt);

  // Local times, because a rota is read in the day the shop is in.
  DateTime at(int day, int hour) => DateTime(2026, 8, day, hour).toUtc();

  Widget app(List<AttendanceEntry> entries, {DateTime? now}) => MaterialApp(
        home: AttendanceReportScreen(
          entries: entries,
          staffNames: const {'sara': 'Sara', 'omar': 'Omar'},
          now: now,
        ),
      );

  testWidgets('says so plainly when nobody clocked in', (t) async {
    await t.pumpWidget(app(const []));
    expect(find.byKey(const Key('attendance-report-empty')), findsOneWidget);
  });

  testWidgets('totals the hours per person over the period', (t) async {
    await t.pumpWidget(app([
      entry(1, 'sara', at(10, 9), outAt: at(10, 13)),
      entry(2, 'sara', at(11, 9), outAt: at(11, 14)),
      entry(3, 'omar', at(11, 18), outAt: at(11, 20)),
    ]));

    final byStaff = find.descendant(
        of: find.byKey(const Key('attendance-by-staff')), matching: find.byType(Text));
    final texts = t.widgetList<Text>(byStaff).map((w) => w.data).toList();
    // Sara 4h + 5h, Omar 2h, and the pair totalled.
    expect(texts, containsAllInOrder(['Sara', '9h 0m']));
    expect(texts, containsAllInOrder(['Omar', '2h 0m']));
    expect(texts, containsAllInOrder(['Total', '11h 0m']));
  });

  testWidgets('breaks the same hours down by day, newest first', (t) async {
    await t.pumpWidget(app([
      entry(1, 'sara', at(10, 9), outAt: at(10, 13)),
      entry(2, 'sara', at(11, 9), outAt: at(11, 14)),
      // Two shifts on one day fold into that day's row.
      entry(3, 'sara', at(11, 18), outAt: at(11, 20)),
    ]));

    final byDay = find.descendant(
        of: find.byKey(const Key('attendance-by-day')), matching: find.byType(Text));
    final texts = t.widgetList<Text>(byDay).map((w) => w.data).toList();
    expect(texts.first, 'Sara · 2026-08-11');
    expect(texts, contains('2 shifts'));
    expect(texts, contains('7h 0m'));
    expect(texts, contains('Sara · 2026-08-10'));
  });

  testWidgets('a shift still running counts up to now and says it is open',
      (t) async {
    await t.pumpWidget(app(
      [entry(1, 'sara', at(12, 9))],
      now: at(12, 12),
    ));

    final texts = t
        .widgetList<Text>(find.descendant(
            of: find.byKey(const Key('attendance-by-day')),
            matching: find.byType(Text)))
        .map((w) => w.data)
        .toList();
    expect(texts, contains('3h 0m'));
    expect(texts.any((s) => s!.contains('still on the clock')), isTrue);
  });

  testWidgets('an id with no name still shows as a row', (t) async {
    await t.pumpWidget(MaterialApp(
      home: AttendanceReportScreen(
        entries: [entry(1, 'ghost', at(10, 9), outAt: at(10, 10))],
        staffNames: const {},
      ),
    ));
    expect(find.text('ghost'), findsOneWidget);
  });

  test('hours are shown in hours and minutes, and exported as decimals', () {
    expect(AttendanceReportScreen.hm(const Duration(hours: 7, minutes: 30)), '7h 30m');
    expect(AttendanceReportScreen.hm(const Duration(minutes: 45)), '45m');
    expect(
        AttendanceReportScreen.decimalHours(const Duration(hours: 7, minutes: 30)),
        '7.50');
  });
}
