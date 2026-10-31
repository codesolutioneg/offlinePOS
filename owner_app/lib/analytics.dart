import 'orders.dart';

class ChartPoint {
  const ChartPoint(this.label, this.value);
  final String label;
  final double value;
}

/// Sales buckets for the dashboard chart (website-aligned: total, no refunds).
List<ChartPoint> salesTrend(List<OwnerOrder> completed, String period) {
  final sales = salesForReports(completed);
  if (period == 'last7') {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return [
      for (var i = 6; i >= 0; i--)
        () {
          final day = today.subtract(Duration(days: i));
          final next = day.add(const Duration(days: 1));
          final sum = sales
              .where((o) {
                final t = o.createdAt.toLocal();
                return !t.isBefore(day) && t.isBefore(next);
              })
              .fold(0.0, (s, o) => s + o.total);
          return ChartPoint('${day.day}/${day.month}', sum);
        }(),
    ];
  }

  // Today / yesterday: by hour 8→23 + overnight bucket.
  final buckets = List<double>.filled(24, 0);
  for (final o in sales) {
    final h = o.createdAt.toLocal().hour;
    buckets[h] += o.total;
  }
  final hours = [8, 10, 12, 14, 16, 18, 20, 22];
  return [
    for (final h in hours)
      ChartPoint(
        '$h',
        buckets[h] + (h + 1 < 24 ? buckets[h + 1] : 0),
      ),
  ];
}

List<ChartPoint> salesByType(List<OwnerOrder> completed) {
  final map = <String, double>{};
  for (final o in salesForReports(completed)) {
    final key = o.orderType.trim().isEmpty ? '—' : o.orderType.trim();
    map[key] = (map[key] ?? 0) + o.total;
  }
  final list = map.entries.map((e) => ChartPoint(e.key, e.value)).toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return list;
}

List<ChartPoint> salesByPayment(List<OwnerOrder> completed) {
  final map = <String, double>{};
  for (final o in salesForReports(completed)) {
    if (o.payments.isEmpty) {
      map['Cash'] = (map['Cash'] ?? 0) + o.total;
      continue;
    }
    for (final p in o.payments) {
      final label =
          (p.label ?? 'Cash').trim().isEmpty ? 'Cash' : p.label!.trim();
      map[label] = (map[label] ?? 0) + p.amount;
    }
  }
  final list = map.entries.map((e) => ChartPoint(e.key, e.value)).toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return list;
}

List<({String name, double qty, double net})> topItems(
  List<OwnerOrder> completed, {
  int limit = 8,
}) {
  final map = <String, ({double qty, double net})>{};
  for (final o in salesForReports(completed)) {
    for (final l in o.lines) {
      final prev = map[l.name] ?? (qty: 0.0, net: 0.0);
      map[l.name] = (qty: prev.qty + l.quantity, net: prev.net + l.total);
    }
  }
  final list = map.entries
      .map((e) => (name: e.key, qty: e.value.qty, net: e.value.net))
      .toList()
    ..sort((a, b) => b.net.compareTo(a.net));
  return list.take(limit).toList();
}
