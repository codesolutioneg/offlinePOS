import 'dart:convert';

import 'attendance_entry.dart';
import 'shift.dart';
import 'shift_movement.dart';

/// What the reports read about drawers: the till answers from its database and
/// the reports site from rows the tills uploaded, through the same calls.
abstract interface class ReportShifts {
  Shift? currentOpenShift();
  List<Shift> recentClosed({int limit = 10});
  List<ShiftMovement> movements({DateTime? from, DateTime? to, String? cashierId});
}

/// What the reports read about staff clock-ins.
abstract interface class ReportAttendance {
  List<AttendanceEntry> between({DateTime? from, DateTime? to, String? staffId});
}

/// What the reports read from the audit trail: rows shaped like the till's
/// `audit_log` table, newest first.
abstract interface class ReportAudit {
  List<Map<String, Object?>> recent({
    int limit = 500,
    String? event,
    String? actor,
    DateTime? from,
    DateTime? to,
  });
}

/// A row of the till's shifts table. The movements column is the JSON text the
/// till stores, or the list itself once it has been through another decoder.
Shift shiftFromRow(Map<String, Object?> r) {
  final raw = r['movements'] ?? '[]';
  final list = raw is String ? jsonDecode(raw) as List : raw as List;
  return Shift(
    id: r['id'] as String,
    uuid: r['uuid'] as String?,
    openedAt: DateTime.parse(r['opened_at'] as String),
    closedAt:
        r['closed_at'] == null ? null : DateTime.parse(r['closed_at'] as String),
    openingFloat: (r['opening_float'] as num).toDouble(),
    cashierId: r['cashier_id'] as String,
    closingCounted: (r['closing_counted'] as num?)?.toDouble(),
    movements: list
        .map((e) => CashMovement.fromMap((e as Map).cast<String, dynamic>()))
        .toList(),
  );
}

/// The cash movements of [shifts] that fall between [from] (inclusive) and [to]
/// (exclusive), oldest first. A null bound is open on that side.
List<ShiftMovement> movementsOf(Iterable<Shift> shifts,
    {DateTime? from, DateTime? to, String? cashierId}) {
  final out = <ShiftMovement>[];
  for (final shift in shifts) {
    if (cashierId != null && shift.cashierId != cashierId) continue;
    for (final m in shift.movements) {
      final at = m.at.toUtc();
      if (from != null && at.isBefore(from.toUtc())) continue;
      if (to != null && !at.isBefore(to.toUtc())) continue;
      out.add(ShiftMovement(
          movement: m, shiftId: shift.id, cashierId: shift.cashierId));
    }
  }
  out.sort((a, b) => a.movement.at.compareTo(b.movement.at));
  return out;
}

/// [ReportShifts] over shifts already in memory.
class MemoryReportShifts implements ReportShifts {
  MemoryReportShifts(Iterable<Shift> shifts) : _shifts = shifts.toList();

  final List<Shift> _shifts;

  @override
  Shift? currentOpenShift() {
    Shift? newest;
    for (final s in _shifts) {
      if (s.closedAt != null) continue;
      if (newest == null || s.openedAt.isAfter(newest.openedAt)) newest = s;
    }
    return newest;
  }

  @override
  List<Shift> recentClosed({int limit = 10}) {
    final closed = [
      for (final s in _shifts)
        if (s.closedAt != null) s
    ]..sort((a, b) => b.closedAt!.compareTo(a.closedAt!));
    return closed.take(limit).toList();
  }

  @override
  List<ShiftMovement> movements(
          {DateTime? from, DateTime? to, String? cashierId}) =>
      movementsOf(_shifts, from: from, to: to, cashierId: cashierId);
}

/// [ReportAttendance] over clock-ins already in memory.
class MemoryReportAttendance implements ReportAttendance {
  MemoryReportAttendance(Iterable<AttendanceEntry> entries)
      : _entries = entries.toList()
          ..sort((a, b) => a.clockIn.compareTo(b.clockIn));

  final List<AttendanceEntry> _entries;

  @override
  List<AttendanceEntry> between(
          {DateTime? from, DateTime? to, String? staffId}) =>
      [
        for (final e in _entries)
          if ((from == null || !e.clockIn.isBefore(from.toUtc())) &&
              (to == null || e.clockIn.isBefore(to.toUtc())) &&
              (staffId == null || e.staffId == staffId))
            e
      ];
}

/// [ReportAudit] over audit rows already in memory, from any number of tills.
class MemoryReportAudit implements ReportAudit {
  MemoryReportAudit(Iterable<Map<String, Object?>> rows)
      : _rows = rows.toList()
          ..sort((a, b) => '${b['at']}'.compareTo('${a['at']}'));

  final List<Map<String, Object?>> _rows;

  @override
  List<Map<String, Object?>> recent({
    int limit = 500,
    String? event,
    String? actor,
    DateTime? from,
    DateTime? to,
  }) {
    final lo = from?.toUtc().toIso8601String();
    final hi = to?.toUtc().toIso8601String();
    return _rows
        .where((r) =>
            (event == null || r['event'] == event) &&
            (actor == null || r['actor'] == actor) &&
            (lo == null || '${r['at']}'.compareTo(lo) >= 0) &&
            (hi == null || '${r['at']}'.compareTo(hi) <= 0))
        .take(limit)
        .toList();
  }
}
