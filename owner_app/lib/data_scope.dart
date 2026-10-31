import 'api.dart';
import 'orders.dart';
import 'sessions.dart';
import 'shift_days.dart';

/// Loads orders + costs + sessions for a branch/period.
///
/// Completed sales are bucketed by shift-open day (same as the website home).
class OwnerData {
  OwnerData(this.api);

  final OwnerApi api;

  /// Completed sales in the selected period (paid/synced), by shift day.
  List<OwnerOrder> completed = const [];

  /// Shifts overlapping the period (and any still open).
  List<OwnerSessionInfo> sessions = const [];

  Map<int, double> costs = const {};
  Object? error;

  int get openSessionCount => sessions.where((s) => s.isOpen).length;
  int get closedSessionCount => sessions.where((s) => !s.isOpen).length;

  /// Orders used by KPI / report screens.
  List<OwnerOrder> get orders => completed;

  static DateTime _plusDays(DateTime d, int n) =>
      DateTime(d.year, d.month, d.day + n);

  Future<void> load({
    String? branchId,
    required DateTime from,
    required DateTime to,
  }) async {
    error = null;
    try {
      // Costs are a catalogue snapshot — their `at` is often null, so do not
      // date-filter them or margin stays equal to net sales.
      final costRows = await api.records(
        const ['costs'],
        branchId: branchId,
      );
      costs = costsFromRecords([
        for (final r in costRows)
          if (r.kind == 'costs') r.payload,
      ]);

      // Shifts opened up to a week before [from] can still claim sales after it.
      // Also pull recent open shifts that may have no `to` bound yet.
      final shiftRows = await api.records(
        const ['shift'],
        branchId: branchId,
        from: _plusDays(from, -7),
      );
      final allSessions = sessionsFromRecords([
        for (final r in shiftRows)
          if (r.kind == 'shift')
            (key: r.key, branchId: r.branchId, payload: r.payload),
      ]);
      sessions = sessionsInWindow(allSessions, from: from, to: to);

      final shifts = ShiftDays([
        for (final r in shiftRows)
          if (r.kind == 'shift') (key: r.key, payload: r.payload),
      ]);

      // A shift opened before [to] can sell past midnight — over-fetch one day.
      final saleRows = await api.records(
        const ['order'],
        branchId: branchId,
        from: from,
        to: _plusDays(to, 1),
      );

      final completedByUuid = <String, OwnerOrder>{};
      for (final r in saleRows) {
        if (r.kind != 'order') continue;
        final o = OwnerOrder.fromRecord(r.payload, branchId: r.branchId);
        if (o.uuid.isEmpty || !o.isCompleted) continue;
        final day = shifts.dayOf(o);
        if (day.isBefore(from) || !day.isBefore(to)) continue;
        completedByUuid[o.uuid] = o;
      }

      completed = completedByUuid.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } catch (e) {
      error = e;
      completed = const [];
      sessions = const [];
      costs = const {};
    }
  }
}
