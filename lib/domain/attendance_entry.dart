/// One clock-in (and later clock-out) for a member of staff.
class AttendanceEntry {
  const AttendanceEntry({
    required this.id,
    required this.staffId,
    required this.clockIn,
    this.clockOut,
  });

  final int id;
  final String staffId;
  final DateTime clockIn;
  final DateTime? clockOut;

  bool get isOpen => clockOut == null;

  /// Worked time so far (to now if still open), for the day's timesheet.
  Duration worked(DateTime now) => (clockOut ?? now).difference(clockIn);

  Map<String, dynamic> toMap() => {
        'staff_id': staffId,
        'clock_in': clockIn.toUtc().toIso8601String(),
        'clock_out': clockOut?.toUtc().toIso8601String(),
      };

  factory AttendanceEntry.fromMap(Map<String, dynamic> m) => AttendanceEntry(
        id: 0,
        staffId: '${m['staff_id']}',
        clockIn: DateTime.parse('${m['clock_in']}').toUtc(),
        clockOut: m['clock_out'] == null
            ? null
            : DateTime.parse('${m['clock_out']}').toUtc(),
      );

  /// A row of the till's attendance table, as the store and the reports site
  /// both read it.
  factory AttendanceEntry.fromRow(Map<String, Object?> r) => AttendanceEntry(
        id: (r['id'] as num?)?.toInt() ?? 0,
        staffId: r['staff_id'] as String,
        clockIn: DateTime.parse(r['clock_in'] as String),
        clockOut: r['clock_out'] == null
            ? null
            : DateTime.parse(r['clock_out'] as String),
      );
}
