import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../domain/order.dart';
import 'report_export.dart';

/// One local hour-of-day bucket: how many orders were rung and how much they
/// were worth. Kept separate from [Order] because the report only cares
/// about the hour, never which specific order landed in it.
class _HourAggregate {
  _HourAggregate({required this.hour, required this.count, required this.total});
  final int hour;
  final int count;
  final double total;
}

/// One local day-of-week bucket (1 = Monday, matching [DateTime.weekday]).
class _DayAggregate {
  _DayAggregate({required this.weekday, required this.count, required this.total});
  final int weekday;
  final int count;
  final double total;
}

/// A rush-hours report: bins every order by the local hour it was rung, so a
/// manager can see when the till is busiest at a glance.
///
/// [Order.createdAt] is stored in UTC (so a synced order is unambiguous no
/// matter which server or device reads it back), but a manager reasons in
/// wall-clock time ("we're slammed at lunch"), so this screen converts to
/// local time before bucketing. It is a pure view over the orders handed in:
/// the caller decides what "today" means and never touches storage itself.
class SalesByTimeReportScreen extends StatelessWidget {
  const SalesByTimeReportScreen({super.key, required this.orders, required this.formatAmount});
  final List<Order> orders;
  final String Function(double) formatAmount;

  /// Buckets orders by local hour-of-day (0-23) and sorts chronologically, so
  /// the report reads left-to-right the way the trading day unfolded. Hours
  /// with no orders are dropped rather than padded with zero-rows: a report
  /// that only shows two open hours a day should not scroll through 22 empty
  /// ones to find them.
  List<_HourAggregate> _byHour() {
    final counts = <int, int>{};
    final totals = <int, double>{};
    for (final o in orders) {
      final hour = o.createdAt.toLocal().hour;
      counts[hour] = (counts[hour] ?? 0) + 1;
      totals[hour] = (totals[hour] ?? 0) + o.total;
    }
    final list = [
      for (final hour in counts.keys)
        _HourAggregate(hour: hour, count: counts[hour]!, total: totals[hour]!),
    ]..sort((a, b) => a.hour.compareTo(b.hour));
    return list;
  }

  String _hourLabel(int hour) => '${hour.toString().padLeft(2, '0')}:00';

  /// Buckets orders by local day of the week, Monday first, dropping days with
  /// no trade for the same reason the hour buckets do. A shop closed on Mondays
  /// should not read a row of zeroes every week.
  List<_DayAggregate> _byWeekday() {
    final counts = <int, int>{};
    final totals = <int, double>{};
    for (final o in orders) {
      final day = o.createdAt.toLocal().weekday;
      counts[day] = (counts[day] ?? 0) + 1;
      totals[day] = (totals[day] ?? 0) + o.total;
    }
    return [
      for (final day in counts.keys)
        _DayAggregate(weekday: day, count: counts[day]!, total: totals[day]!),
    ]..sort((a, b) => a.weekday.compareTo(b.weekday));
  }

  static const _weekdayNames = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];

  ReportTable _table() => ReportTable(
        header: const ['Section', 'When', 'Orders', 'Total'],
        rows: [
          for (final h in _byHour())
            ['Hour', _hourLabel(h.hour), '${h.count}', h.total.toStringAsFixed(2)],
          for (final d in _byWeekday())
            ['Weekday', _weekdayNames[d.weekday - 1], '${d.count}',
                d.total.toStringAsFixed(2)],
        ],
      );

  @override
  Widget build(BuildContext context) {
    final hours = _byHour();
    final days = _byWeekday();

    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Sales by hour')),
        actions: [
          reportExportAction(context,
              name: 'report-sales-by-hour',
              title: tr(context, 'Sales by hour'),
              table: _table),
        ],
      ),
      body: orders.isEmpty
          ? Center(child: Text(tr(context, 'No orders')))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                _hoursCard(context, hours),
                const SizedBox(height: 12),
                _daysCard(context, days),
              ]),
            ),
    );
  }

  Widget _daysCard(BuildContext context, List<_DayAggregate> days) {
    final peakTotal = days.fold(0.0, (m, d) => d.total > m ? d.total : m);
    final safePeak = peakTotal <= 0 ? 1.0 : peakTotal;
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr(context, 'By day of week'),
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const Divider(),
            Column(
              key: const Key('weekday-sales-list'),
              children: [
                for (final d in days)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(children: [
                      SizedBox(
                        width: 84,
                        child: Text(tr(context, _weekdayNames[d.weekday - 1])),
                      ),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: (d.total / safePeak).clamp(0.0, 1.0),
                            child: Container(
                              height: 20,
                              decoration: BoxDecoration(
                                color: colorScheme.primary.withValues(
                                    alpha: d.total == peakTotal ? 1.0 : 0.35),
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                          width: 32,
                          child: Text('${d.count}', textAlign: TextAlign.right)),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 80,
                        child: Text(formatAmount(d.total),
                            textAlign: TextAlign.right),
                      ),
                    ]),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _hoursCard(BuildContext context, List<_HourAggregate> hours) {
    // The peak hour's total is the yardstick every bar is drawn against, so
    // the busiest hour always renders at full width and every other hour
    // reads as a fraction of it. Guarded against zero so a day of entirely
    // free/comped orders doesn't divide by zero.
    final peakTotal = hours.fold(0.0, (m, h) => h.total > m ? h.total : m);
    final safePeak = peakTotal <= 0 ? 1.0 : peakTotal;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr(context, 'By hour'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const Divider(),
            ListView.builder(
              key: const Key('hourly-sales-list'),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: hours.length,
              itemBuilder: (context, i) {
                final h = hours[i];
                return _hourRow(context, h, h.total == peakTotal, safePeak);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _hourRow(BuildContext context, _HourAggregate h, bool isPeak, double safePeak) {
    final colorScheme = Theme.of(context).colorScheme;
    final barColor = isPeak ? colorScheme.primary : colorScheme.primary.withValues(alpha: 0.35);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(
              _hourLabel(h.hour),
              style: TextStyle(fontWeight: isPeak ? FontWeight.bold : FontWeight.normal),
            ),
          ),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              // The bar's width is the hour's share of the peak hour's total,
              // so a glance across the list shows the shape of the day.
              child: FractionallySizedBox(
                widthFactor: (h.total / safePeak).clamp(0.0, 1.0),
                child: Container(
                  height: 20,
                  decoration: BoxDecoration(color: barColor, borderRadius: BorderRadius.circular(4)),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (isPeak) Icon(Icons.trending_up, size: 16, color: colorScheme.primary),
          const SizedBox(width: 8),
          SizedBox(width: 32, child: Text('${h.count}', textAlign: TextAlign.right)),
          const SizedBox(width: 8),
          SizedBox(
            width: 80,
            child: Text(
              formatAmount(h.total),
              textAlign: TextAlign.right,
              style: TextStyle(fontWeight: isPeak ? FontWeight.bold : FontWeight.normal),
            ),
          ),
        ],
      ),
    );
  }
}
