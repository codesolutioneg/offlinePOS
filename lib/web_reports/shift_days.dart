import '../domain/order.dart';
import '../domain/report_sources.dart';
import '../domain/shift.dart';
import 'site_api.dart';

/// Which day a sale counts under: the day its till's shift was opened, so a
/// shift that runs past midnight keeps its late sales on the day it began.
///
/// A sale names no shift, so it is matched by its till and its time: the
/// latest shift on that till opened before it, if the sale falls before that
/// shift closed, before the till's next shift opened and within [longest] of
/// the opening (a close that never reached the server must not pull a week of
/// sales back to one day). A sale no shift claims counts under its own day.
class ShiftDays {
  ShiftDays(Iterable<SiteRecord> records, {this.longest = const Duration(hours: 24)}) {
    for (final r in records) {
      if (r.kind != 'shift') continue;
      final cut = r.key.indexOf(':');
      if (cut <= 0) continue;
      final Shift shift;
      try {
        shift = shiftFromRow(r.payload);
      } catch (_) {
        continue;
      }
      (_byTill[r.key.substring(0, cut)] ??= []).add(shift);
    }
    for (final shifts in _byTill.values) {
      shifts.sort((a, b) => a.openedAt.compareTo(b.openedAt));
    }
  }

  final Duration longest;
  final Map<String, List<Shift>> _byTill = {};

  /// The shift [order] was rung in, or null when none claims it.
  Shift? shiftOf(Order order) {
    final shifts = _byTill[order.deviceId];
    if (shifts == null) return null;
    final at = order.createdAt;
    for (var i = shifts.length - 1; i >= 0; i--) {
      final s = shifts[i];
      if (s.openedAt.isAfter(at)) continue;
      var end = s.openedAt.add(longest);
      final closed = s.closedAt;
      if (closed != null && closed.isBefore(end)) end = closed;
      if (i + 1 < shifts.length && shifts[i + 1].openedAt.isBefore(end)) {
        end = shifts[i + 1].openedAt;
      }
      return at.isAfter(end) ? null : s;
    }
    return null;
  }

  /// Local midnight of the day [order] counts under.
  DateTime dayOf(Order order) {
    final t = (shiftOf(order)?.openedAt ?? order.createdAt).toLocal();
    return DateTime(t.year, t.month, t.day);
  }
}
