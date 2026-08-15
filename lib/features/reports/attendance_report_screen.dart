import 'package:flutter/material.dart';

import '../../core/db/attendance_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/widgets/feedback.dart';
import 'report_export.dart';

/// One person's hours on one trading date.
class _DayRow {
  _DayRow(this.staffId, this.date);
  final String staffId;
  final DateTime date;
  Duration worked = Duration.zero;
  int shifts = 0;
  bool stillOn = false;
}

/// Hours worked per member of staff, per day, over the chosen period.
///
/// Attendance was only ever a live board of who is on the clock; the hours it
/// recorded could not be read back, so nobody could answer "how many hours did she
/// do last week" without counting rows by hand. This is that read: a pure view over
/// the entries the caller has already windowed, local like everything else, so it
/// works with the line down.
///
/// A shift still open is counted up to [now] and marked as running, rather than
/// silently reading as zero.
class AttendanceReportScreen extends StatelessWidget {
  const AttendanceReportScreen({
    super.key,
    required this.entries,
    required this.staffNames,
    this.now,
  });

  final List<AttendanceEntry> entries;

  /// Staff id to the name a manager knows them by. An id with no name shows as
  /// itself rather than as a blank row.
  final Map<String, String> staffNames;

  /// Injectable clock, so a still-open shift measures the same in a test as it
  /// does at the counter.
  final DateTime? now;

  DateTime get _now => now ?? DateTime.now().toUtc();

  String _name(String staffId) => staffNames[staffId] ?? staffId;

  /// The local calendar day a shift started on: what a rota is read in.
  static DateTime _dayOf(DateTime utc) {
    final l = utc.toLocal();
    return DateTime(l.year, l.month, l.day);
  }

  static String _date(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  static String _clock(DateTime utc) {
    final l = utc.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(l.hour)}:${two(l.minute)}';
  }

  /// Hours and minutes, which is how a shop talks about a shift.
  static String hm(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    return h > 0 ? '${h}h ${m}m' : '${m}m';
  }

  /// Decimal hours, which is how a payroll sheet adds them up.
  static String decimalHours(Duration d) =>
      (d.inMinutes / 60).toStringAsFixed(2);

  List<_DayRow> get _days {
    final rows = <String, _DayRow>{};
    for (final e in entries) {
      final day = _dayOf(e.clockIn);
      final key = '${e.staffId}|${_date(day)}';
      final row = rows.putIfAbsent(key, () => _DayRow(e.staffId, day));
      row.worked += e.worked(_now);
      row.shifts += 1;
      if (e.isOpen) row.stillOn = true;
    }
    final list = rows.values.toList();
    // Newest day first, then by name, so the last shift worked is at the top.
    list.sort((a, b) {
      final byDate = b.date.compareTo(a.date);
      return byDate != 0 ? byDate : _name(a.staffId).compareTo(_name(b.staffId));
    });
    return list;
  }

  /// Total per person over the whole period, largest first.
  List<MapEntry<String, Duration>> get _totals {
    final totals = <String, Duration>{};
    for (final e in entries) {
      totals[e.staffId] = (totals[e.staffId] ?? Duration.zero) + e.worked(_now);
    }
    final list = totals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return list;
  }

  Duration get _grandTotal =>
      entries.fold(Duration.zero, (s, e) => s + e.worked(_now));

  Future<void> _csv(BuildContext context) => downloadReportCsv(
        context,
        name: 'report-attendance',
        header: const ['Staff', 'Date', 'In', 'Out', 'Hours'],
        rows: [
          for (final e in entries)
            [
              _name(e.staffId),
              _date(_dayOf(e.clockIn)),
              _clock(e.clockIn),
              e.clockOut == null ? '' : _clock(e.clockOut!),
              decimalHours(e.worked(_now)),
            ],
        ],
      );

  Widget _card(String title, List<Widget> children) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const Divider(),
            ...children,
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final days = _days;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Hours worked')),
        actions: [reportCsvAction(context, onPressed: () => _csv(context))],
      ),
      body: entries.isEmpty
          ? Center(
              child: EmptyState(
                key: const Key('attendance-report-empty'),
                icon: Icons.schedule,
                title: tr(context, 'No hours'),
                message: tr(context, 'Nobody clocked in during this range.'),
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _card(tr(context, 'Per staff member'), [
                    Column(
                      key: const Key('attendance-by-staff'),
                      children: [
                        for (final e in _totals)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(_name(e.key)),
                            trailing: Text(hm(e.value),
                                style: const TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        const Divider(),
                        ListTile(
                          key: const Key('attendance-total'),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(tr(context, 'Total')),
                          trailing: Text(hm(_grandTotal),
                              style: const TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  ]),
                  _card(tr(context, 'Day by day'), [
                    Column(
                      key: const Key('attendance-by-day'),
                      children: [
                        for (final d in days)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text('${_name(d.staffId)} · ${_date(d.date)}'),
                            subtitle: Text([
                              '${d.shifts} ${tr(context, d.shifts == 1 ? 'shift' : 'shifts')}',
                              if (d.stillOn) tr(context, 'still on the clock'),
                            ].join(' · ')),
                            trailing: Text(hm(d.worked)),
                          ),
                      ],
                    ),
                  ]),
                ],
              ),
            ),
    );
  }
}
