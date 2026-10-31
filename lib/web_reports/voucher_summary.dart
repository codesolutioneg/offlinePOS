import 'site_api.dart';

/// How many voucher numbers exist, how many were used, and the money given.
class VoucherTotals {
  const VoucherTotals({
    required this.total,
    required this.used,
    required this.waiting,
    required this.remaining,
    required this.value,
  });

  /// Distinct numbers inside the ranges the owner added.
  final int total;

  /// Numbers already paid.
  final int used;

  /// Numbers held on an open bill.
  final int waiting;

  /// Numbers nobody has taken yet.
  final int remaining;

  /// Discount money on the paid vouchers.
  final double value;
}

/// Counts for one from–to span, including numbers that also sit in another span.
class VoucherRangeCount {
  const VoucherRangeCount({
    required this.from,
    required this.to,
    required this.used,
    required this.waiting,
    required this.remaining,
    required this.value,
  });

  final int from;
  final int to;
  final int used;
  final int waiting;
  final int remaining;
  final double value;
}

VoucherTotals voucherTotals(SiteVouchers data) {
  final covered = _merged(data.ranges);
  final total = covered.fold<int>(0, (sum, span) => sum + span.length);
  final used = <int>{};
  final waiting = <int>{};
  var value = 0.0;
  for (final row in data.rows) {
    if (row.serial <= 0 || !covered.any((span) => span.contains(row.serial))) continue;
    if (row.status == 'used') {
      used.add(row.serial);
      value += row.discountAmount ?? 0;
    } else {
      waiting.add(row.serial);
    }
  }
  waiting.removeAll(used);
  return VoucherTotals(
    total: total,
    used: used.length,
    waiting: waiting.length,
    remaining: total - used.length - waiting.length,
    value: value,
  );
}

List<VoucherRangeCount> voucherRangeCounts(SiteVouchers data) {
  final counts = <VoucherRangeCount>[];
  for (final range in data.ranges) {
    final used = <int>{};
    final waiting = <int>{};
    var value = 0.0;
    for (final row in data.rows) {
      final serial = row.serial;
      if (serial < range.from || serial > range.to) continue;
      if (row.status == 'used') {
        used.add(serial);
        value += row.discountAmount ?? 0;
      } else {
        waiting.add(serial);
      }
    }
    waiting.removeAll(used);
    final total = range.to - range.from + 1;
    counts.add(VoucherRangeCount(
      from: range.from,
      to: range.to,
      used: used.length,
      waiting: waiting.length,
      remaining: total - used.length - waiting.length,
      value: value,
    ));
  }
  return counts;
}

class _Span {
  const _Span(this.from, this.to);

  final int from;
  final int to;

  int get length => to - from + 1;

  bool contains(int serial) => serial >= from && serial <= to;
}

/// Overlapping spans become one run, so a number in two ranges is counted once.
List<_Span> _merged(List<SiteVoucherRange> ranges) {
  final spans = [...ranges]..sort((a, b) => a.from.compareTo(b.from));
  final out = <_Span>[];
  int? start;
  int? end;
  void flush() {
    if (start != null && end != null) out.add(_Span(start, end));
  }

  for (final span in spans) {
    if (span.to < span.from) continue;
    if (start == null) {
      start = span.from;
      end = span.to;
      continue;
    }
    if (span.from <= end! + 1) {
      if (span.to > end) end = span.to;
    } else {
      flush();
      start = span.from;
      end = span.to;
    }
  }
  flush();
  return out;
}
