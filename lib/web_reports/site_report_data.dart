import '../core/cloud/report_lookups.dart';
import '../domain/attendance_entry.dart';
import '../domain/order.dart';
import '../domain/report_sources.dart';
import '../domain/shift.dart';
import 'site_api.dart';

/// What the reports screen reads, for one branch or all of them, from the rows
/// the tills uploaded.
///
/// The screen asks synchronously, as it does of the till's database, so a
/// window is fetched in [prepare] before a report over it opens and read from
/// memory after. A window inside one already fetched is not fetched again.
class SiteReportData implements ReportAttendance, ReportAudit {
  SiteReportData(this._api, {this.branchId, DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final SiteApi _api;

  /// Null for every branch the user may see.
  final String? branchId;
  final DateTime Function() _now;

  ReportLookups lookups = const ReportLookups();
  ReportShifts shifts = MemoryReportShifts(const []);

  final Map<String, Order> _orders = {};
  final Map<String, AttendanceEntry> _attendance = {};
  final Map<String, Map<String, Object?>> _audit = {};
  final List<(DateTime?, DateTime?)> _fetched = [];

  /// Answered from whatever has been fetched by the time a report asks, not
  /// from what was there when the screen was built.
  @override
  List<AttendanceEntry> between({DateTime? from, DateTime? to, String? staffId}) =>
      MemoryReportAttendance(_attendance.values)
          .between(from: from, to: to, staffId: staffId);

  @override
  List<Map<String, Object?>> recent({
    int limit = 500,
    String? event,
    String? actor,
    DateTime? from,
    DateTime? to,
  }) =>
      MemoryReportAudit(_audit.values)
          .recent(limit: limit, event: event, actor: actor, from: from, to: to);

  /// The lookups, every shift, and the last month of sales for the screen's
  /// filters and the glance card.
  Future<void> load() async {
    final rows = await _api.records(
      [...ReportLookups.kinds, 'shift'],
      branchId: branchId,
    );
    lookups = ReportLookups.fromRecords([
      for (final r in rows)
        if (r.kind != 'shift') (kind: r.kind, payload: r.payload),
    ]);
    shifts = MemoryReportShifts([
      for (final r in rows)
        if (r.kind == 'shift') shiftFromRow(r.payload),
    ]);
    final today = _now();
    await prepare(DateTime(today.year, today.month, today.day - 31), null);
  }

  static bool _covers((DateTime?, DateTime?) outer, DateTime? from, DateTime? to) {
    final (lo, hi) = outer;
    final fromOk = lo == null || (from != null && !from.isBefore(lo));
    final toOk = hi == null || (to != null && !to.isAfter(hi));
    return fromOk && toOk;
  }

  /// Fetch the sales, clock-ins and audit entries between [from] and [to].
  Future<void> prepare(DateTime? from, DateTime? to) async {
    if (_fetched.any((w) => _covers(w, from, to))) return;
    final rows = await _api.records(
      const ['order', 'attendance', 'audit'],
      branchId: branchId,
      from: from,
      to: to,
    );
    for (final r in rows) {
      switch (r.kind) {
        case 'order':
          _orders[r.key] = Order.fromMap(r.payload.cast<String, dynamic>());
        case 'attendance':
          _attendance[r.key] = AttendanceEntry.fromRow(r.payload);
        case 'audit':
          _audit[r.key] = r.payload;
      }
    }
    _fetched.add((from, to));
  }

  bool _completed(Order o) =>
      o.state == OrderState.paid || o.state == OrderState.synced;

  /// Completed sales from [from] up to [to] (exclusive), newest first, as the
  /// till's order store answers the same question.
  List<Order> ordersIn(DateTime? from, DateTime? to) {
    final lo = from?.toUtc();
    final hi = to?.toUtc();
    return [
      for (final o in _orders.values)
        if (_completed(o) &&
            (lo == null || !o.createdAt.toUtc().isBefore(lo)) &&
            (hi == null || o.createdAt.toUtc().isBefore(hi)))
          o
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// The most recent completed sales, for the screen's filter lists.
  List<Order> latestOrders({int limit = 1000}) =>
      ordersIn(null, null).take(limit).toList();

  Shift? get openShift => shifts.currentOpenShift();
}
