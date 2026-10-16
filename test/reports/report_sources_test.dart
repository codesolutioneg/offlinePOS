import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/db/attendance_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/shift_store.dart';
import 'package:offline_pos/domain/report_sources.dart';
import 'package:offline_pos/features/reports/report_access.dart';

import '../db/sqlite_loader.dart';

/// The reports site answers from uploaded rows what the till answers from its
/// database. Same rows in, same answers out, or the two would disagree on a
/// figure the owner compares.
void main() {
  late Directory dir;
  late Db db;

  setUpAll(useSystemSqlite);
  setUp(() {
    dir = Directory.systemTemp.createTempSync('pos-sources-test');
    db = Db.open('${dir.path}${Platform.pathSeparator}pos.db');
  });
  tearDown(() {
    db.close();
    dir.deleteSync(recursive: true);
  });

  List<Map<String, Object?>> rows(String table) => [
        for (final r in db.raw.select('SELECT * FROM $table'))
          {for (final k in r.keys) k: r[k]}
      ];

  String movement(String type, double amount, String at, {String? category}) =>
      jsonEncode({
        'type': type,
        'amount': amount,
        'reason': 'r',
        'category': category,
        'at': at,
      });

  test('shifts: open, recent closed and movements match the store', () {
    void shift(String id, String opened, String? closed, String cashier,
        List<String> moves) {
      db.raw.execute(
        'INSERT INTO shifts (id, uuid, opened_at, closed_at, opening_float, cashier_id, movements, closing_counted) '
        'VALUES (?, ?, ?, ?, 100, ?, ?, ?)',
        [id, 'u-$id', opened, closed, cashier, '[${moves.join(',')}]', closed == null ? null : 90],
      );
    }

    shift('SH1', '2026-10-06T08:00:00.000Z', '2026-10-06T20:00:00.000Z', 'a', [
      movement('out', 20, '2026-10-06T09:00:00.000Z', category: 'Food'),
      movement('in', 5, '2026-10-06T19:00:00.000Z'),
    ]);
    shift('SH2', '2026-10-07T08:00:00.000Z', '2026-10-07T21:00:00.000Z', 'b', [
      movement('out', 7, '2026-10-07T12:00:00.000Z', category: 'Transport'),
    ]);
    shift('SH3', '2026-10-08T08:00:00.000Z', null, 'a', [
      movement('out', 3, '2026-10-08T09:30:00.000Z'),
    ]);

    final store = ShiftStore(db);
    final memory = MemoryReportShifts(rows('shifts').map(shiftFromRow));

    expect(memory.currentOpenShift()?.id, store.currentOpenShift()?.id);
    expect(memory.recentClosed(limit: 50).map((s) => s.id),
        store.recentClosed(limit: 50).map((s) => s.id));
    String flat(List<ShiftMovement> m) => m
        .map((x) => '${x.shiftId}/${x.cashierId}/${x.movement.type}/${x.movement.amount}')
        .join(' ');
    for (final (from, to, cashier) in [
      (null, null, null),
      (DateTime.utc(2026, 10, 6, 10), DateTime.utc(2026, 10, 8), null),
      (DateTime.utc(2026, 10, 6), null, 'a'),
    ]) {
      expect(flat(memory.movements(from: from, to: to, cashierId: cashier)),
          flat(store.movements(from: from, to: to, cashierId: cashier)));
    }
  });

  test('attendance: between matches the store', () {
    for (final (who, at) in [
      ('a', '2026-10-07T08:00:00.000Z'),
      ('b', '2026-10-07T09:00:00.000Z'),
      ('a', '2026-10-08T08:00:00.000Z'),
    ]) {
      db.raw.execute(
          'INSERT INTO attendance (staff_id, clock_in) VALUES (?, ?)', [who, at]);
    }
    final store = AttendanceStore(db);
    final memory =
        MemoryReportAttendance(rows('attendance').map(AttendanceEntry.fromRow));
    for (final (from, to, who) in [
      (null, null, null),
      (DateTime.utc(2026, 10, 7, 8, 30), null, null),
      (null, DateTime.utc(2026, 10, 8), 'a'),
    ]) {
      expect(
          memory.between(from: from, to: to, staffId: who).map((e) => e.clockIn),
          store.between(from: from, to: to, staffId: who).map((e) => e.clockIn));
    }
  });

  test('audit: recent matches the log', () {
    var clock = DateTime.utc(2026, 10, 8, 9);
    final log = AuditLog(db, now: () => clock);
    for (final (who, what) in [
      ('a', 'line.voided'),
      ('b', 'order.cancelled'),
      ('a', 'order.cancelled'),
    ]) {
      clock = clock.add(const Duration(minutes: 5));
      log.record(who, what, detail: 'x|y|z');
    }
    final memory = MemoryReportAudit(rows('audit_log'));
    for (final (event, actor, from) in [
      (null, null, null),
      ('order.cancelled', null, null),
      ('order.cancelled', 'a', DateTime.utc(2026, 10, 8, 9, 6)),
    ]) {
      expect(
          memory.recent(event: event, actor: actor, from: from).map((r) => r['id']),
          log.recent(event: event, actor: actor, from: from).map((r) => r['id']));
    }
  });

  test('a report that needs a capability is hidden without it', () {
    expect(canOpenReport('rep-summary', {}), isTrue);
    expect(canOpenReport('rep-cost-sales', {}), isFalse);
    expect(canOpenReport('rep-cost-sales', {'costs'}), isTrue);
    expect(canOpenReport('rm-123', {'flash'}), isFalse);
    expect(canOpenReport('rm-123', {'backoffice'}), isTrue);
    expect(canOpenReport('rep-flash', {'flash'}), isTrue);
  });
}
