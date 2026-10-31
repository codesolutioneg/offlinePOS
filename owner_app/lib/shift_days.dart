import 'orders.dart';

/// Which day a sale counts under: the day its till's shift opened (matches
/// website `ShiftDays` in `lib/web_reports/shift_days.dart`).
class ShiftDays {
  ShiftDays(
    Iterable<({String key, Map<String, Object?> payload})> records, {
    this.longest = const Duration(hours: 24),
  }) {
    for (final r in records) {
      final cut = r.key.indexOf(':');
      if (cut <= 0) continue;
      final opened = DateTime.tryParse('${r.payload['opened_at'] ?? ''}');
      if (opened == null) continue;
      final closedRaw = r.payload['closed_at'];
      final closed = closedRaw == null
          ? null
          : DateTime.tryParse('$closedRaw');
      (_byTill[r.key.substring(0, cut)] ??= []).add(
        _Shift(openedAt: opened.toUtc(), closedAt: closed?.toUtc()),
      );
    }
    for (final shifts in _byTill.values) {
      shifts.sort((a, b) => a.openedAt.compareTo(b.openedAt));
    }
  }

  final Duration longest;
  final Map<String, List<_Shift>> _byTill = {};

  _Shift? _shiftOf(OwnerOrder order) {
    final shifts = _byTill[order.deviceId];
    if (shifts == null || order.deviceId.isEmpty) return null;
    final at = order.createdAt.toUtc();
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
  DateTime dayOf(OwnerOrder order) {
    final t = (_shiftOf(order)?.openedAt ?? order.createdAt).toLocal();
    return DateTime(t.year, t.month, t.day);
  }
}

class _Shift {
  const _Shift({required this.openedAt, this.closedAt});
  final DateTime openedAt;
  final DateTime? closedAt;
}
