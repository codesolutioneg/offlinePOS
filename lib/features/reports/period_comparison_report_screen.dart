import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/order.dart';
import 'report_export.dart';

/// One line of the comparison: the same measure on both periods.
class _Kpi {
  _Kpi(this.label, this.current, this.previous, {this.money = true});
  final String label;
  final double current;
  final double previous;

  /// Counts are shown whole; everything else goes through the money formatter.
  final bool money;

  double get delta => current - previous;

  /// Growth against the previous period. Null when there is nothing to compare
  /// against: a first week of trading is not "infinite growth".
  double? get percent => previous == 0 ? null : delta / previous * 100;
}

/// This period against the one before it, measure by measure.
///
/// Both order lists are windowed by the caller, so this stays a pure view and the
/// hub owns what "the period before" means.
class PeriodComparisonReportScreen extends StatelessWidget {
  const PeriodComparisonReportScreen({
    super.key,
    required this.current,
    required this.previous,
    required this.currentLabel,
    required this.previousLabel,
    required this.formatAmount,
  });

  final List<Order> current;
  final List<Order> previous;
  final String currentLabel;
  final String previousLabel;
  final String Function(double) formatAmount;

  static double _gross(List<Order> o) => o.fold(0.0, (s, x) => s + x.total);

  static double _discounts(List<Order> o) =>
      o.fold(0.0, (s, x) => s + x.subtotal * x.discountPercent / 100);

  static double _tips(List<Order> o) => o.fold(0.0, (s, x) => s + x.tip);

  static double _average(List<Order> o) =>
      o.isEmpty ? 0 : _gross(o) / o.length;

  List<_Kpi> get _kpis => [
        _Kpi('Orders', current.length.toDouble(), previous.length.toDouble(),
            money: false),
        _Kpi('Gross sales', _gross(current), _gross(previous)),
        _Kpi('Average ticket', _average(current), _average(previous)),
        _Kpi('Discounts', _discounts(current), _discounts(previous)),
        _Kpi('Tips', _tips(current), _tips(previous)),
      ];

  String _value(_Kpi k, double v) =>
      k.money ? formatAmount(v) : v.toStringAsFixed(0);

  Future<void> _csv(BuildContext context) => downloadReportCsv(
        context,
        name: 'report-period-comparison',
        header: const ['Measure', 'Current', 'Previous', 'Change', 'Change %'],
        rows: [
          for (final k in _kpis)
            [
              k.label,
              k.current.toStringAsFixed(2),
              k.previous.toStringAsFixed(2),
              k.delta.toStringAsFixed(2),
              k.percent == null ? '' : k.percent!.toStringAsFixed(1),
            ],
        ],
      );

  @override
  Widget build(BuildContext context) {
    final kpis = _kpis;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Period comparison')),
        actions: [reportCsvAction(context, onPressed: () => _csv(context))],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$currentLabel  vs  $previousLabel',
                    key: const Key('comparison-periods'),
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16)),
                if (previous.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      tr(context, 'Nothing was sold in the earlier period.'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                const Divider(),
                Column(
                  key: const Key('comparison-rows'),
                  children: [for (final k in kpis) _row(context, k)],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, _Kpi k) {
    // Down is only bad on takings; a fall in discounts is a good week. The
    // colour therefore follows the direction, and the manager reads the measure.
    final up = k.delta > 0;
    final flat = k.delta == 0;
    final color = flat
        ? Theme.of(context).colorScheme.outline
        : (up ? AppColors.success : AppColors.error);
    final percent = k.percent;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(child: Text(tr(context, k.label))),
        SizedBox(
          width: 80,
          child: Text(_value(k, k.current), textAlign: TextAlign.right),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 80,
          child: Text(_value(k, k.previous),
              textAlign: TextAlign.right,
              style: TextStyle(color: Theme.of(context).colorScheme.outline)),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 76,
          child: Text(
            // With nothing in the earlier period a percentage would be a lie, so
            // the row says so rather than printing an invented number.
            percent == null
                ? (flat ? '=' : tr(context, 'new'))
                : '${percent >= 0 ? '+' : ''}${percent.toStringAsFixed(0)}%',
            textAlign: TextAlign.right,
            style: TextStyle(color: color, fontWeight: FontWeight.bold),
          ),
        ),
      ]),
    );
  }
}
