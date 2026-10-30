import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../analytics.dart';
import '../api.dart';
import '../l10n.dart';
import '../theme.dart';

class OwnerCard extends StatelessWidget {
  const OwnerCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.onTap,
    this.color = Colors.white,
  });

  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final body = Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F172A).withValues(alpha: 0.06),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: child,
    );
    if (onTap == null) return body;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: body,
      ),
    );
  }
}

class PeriodBar extends StatelessWidget {
  const PeriodBar({
    super.key,
    required this.period,
    required this.onChanged,
    this.customLabel,
    this.onCustom,
    this.arabic = false,
  });

  final String period;
  final ValueChanged<String> onChanged;

  /// Shown under the bar when a custom range is active.
  final String? customLabel;

  /// Opens a date-range picker; parent should pass [onCustom].
  final VoidCallback? onCustom;
  final bool arabic;

  @override
  Widget build(BuildContext context) {
    final items = [
      ('today', arabic ? 'اليوم' : 'Today'),
      ('yesterday', arabic ? 'أمس' : 'Yest.'),
      ('last7', arabic ? '٧ أيام' : '7 days'),
    ];
    final customSelected = period == 'custom';

    Widget segment({
      required bool selected,
      required VoidCallback onTap,
      required Widget child,
      bool flex = true,
    }) {
      final body = AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: EdgeInsets.symmetric(
          horizontal: flex ? 4 : 12,
          vertical: 10,
        ),
        decoration: BoxDecoration(
          color: selected ? AppColors.navy : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: AppColors.navy.withValues(alpha: 0.22),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ]
              : null,
        ),
        child: DefaultTextStyle(
          style: GoogleFonts.cairo(
            fontWeight: FontWeight.w700,
            fontSize: 12.5,
            height: 1.1,
            color: selected ? Colors.white : AppColors.muted,
          ),
          child: IconTheme(
            data: IconThemeData(
              size: 18,
              color: selected ? Colors.white : AppColors.skyDark,
            ),
            child: Center(child: child),
          ),
        ),
      );

      final tap = Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: body,
        ),
      );

      return flex ? Expanded(child: tap) : tap;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: const Color(0xFFE8EEF5),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFD9E2EC)),
          ),
          child: Row(
            children: [
              for (final (key, label) in items)
                segment(
                  selected: period == key,
                  onTap: () => onChanged(key),
                  child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              segment(
                selected: customSelected,
                flex: false,
                onTap: () {
                  if (onCustom != null) {
                    onCustom!();
                  } else {
                    onChanged('custom');
                  }
                },
                child: const Icon(Icons.calendar_month_rounded),
              ),
            ],
          ),
        ),
        if (customSelected && customLabel != null && customLabel!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.date_range_rounded,
                  size: 14, color: AppColors.skyDark.withValues(alpha: 0.9)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  customLabel!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.cairo(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.skyDark,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class BranchScopeBar extends StatelessWidget {
  const BranchScopeBar({
    super.key,
    required this.branches,
    required this.branchId,
    required this.onChanged,
  });

  final List<OwnerBranch> branches;
  final String? branchId;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    if (branches.isEmpty) {
      return Text(tr(context, 'No branches assigned'),
          style: GoogleFonts.cairo(color: AppColors.danger));
    }
    if (branches.length == 1) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF0F172A).withValues(alpha: 0.05),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFE0F2FE),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.storefront_rounded,
                  size: 18, color: AppColors.skyDark),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(branches.single.name,
                  style: GoogleFonts.cairo(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: AppColors.navy)),
            ),
          ],
        ),
      );
    }
    return DropdownButtonFormField<String?>(
      key: ValueKey(branchId ?? 'all'),
      initialValue: branchId,
      decoration: InputDecoration(
        labelText: tr(context, 'Branch'),
        prefixIcon: const Icon(Icons.storefront_outlined),
        isDense: true,
        filled: true,
        fillColor: Colors.white,
      ),
      items: [
        DropdownMenuItem(
            value: null, child: Text(tr(context, 'All branches'))),
        for (final b in branches)
          DropdownMenuItem(value: b.id, child: Text(b.name)),
      ],
      onChanged: onChanged,
    );
  }
}

class SalesTrendChart extends StatelessWidget {
  const SalesTrendChart({super.key, required this.points, required this.title});

  final List<ChartPoint> points;
  final String title;

  @override
  Widget build(BuildContext context) {
    final maxY = points.fold<double>(0, (m, p) => p.value > m ? p.value : m);
    final niceMax = maxY <= 0 ? 1.0 : maxY * 1.15;
    final spots = [
      for (var i = 0; i < points.length; i++)
        FlSpot(i.toDouble(), points[i].value),
    ];

    return OwnerCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: GoogleFonts.cairo(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  color: AppColors.navy)),
          const SizedBox(height: 18),
          SizedBox(
            height: 200,
            child: points.every((p) => p.value == 0)
                ? Center(
                    child: Text(tr(context, 'No data in this period'),
                        style: GoogleFonts.cairo(color: AppColors.muted)))
                : LineChart(
                    LineChartData(
                      minY: 0,
                      maxY: niceMax,
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        horizontalInterval: niceMax / 4,
                        getDrawingHorizontalLine: (v) => FlLine(
                          color: AppColors.border.withValues(alpha: 0.7),
                          strokeWidth: 1,
                          dashArray: [4, 4],
                        ),
                      ),
                      borderData: FlBorderData(show: false),
                      titlesData: FlTitlesData(
                        topTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        rightTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        leftTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 28,
                            interval: 1,
                            getTitlesWidget: (v, meta) {
                              final i = v.toInt();
                              if (i < 0 || i >= points.length) {
                                return const SizedBox.shrink();
                              }
                              return Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  points[i].label,
                                  style: GoogleFonts.cairo(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.muted),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      lineTouchData: LineTouchData(
                        touchTooltipData: LineTouchTooltipData(
                          getTooltipColor: (_) => AppColors.navy,
                          getTooltipItems: (touched) => [
                            for (final t in touched)
                              LineTooltipItem(
                                t.y.toStringAsFixed(0),
                                GoogleFonts.cairo(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                          ],
                        ),
                      ),
                      lineBarsData: [
                        LineChartBarData(
                          spots: spots,
                          isCurved: true,
                          curveSmoothness: 0.35,
                          barWidth: 3.2,
                          color: AppColors.skyDark,
                          dotData: FlDotData(
                            show: true,
                            getDotPainter: (s, p, b, i) => FlDotCirclePainter(
                              radius: 3.5,
                              color: Colors.white,
                              strokeWidth: 2.5,
                              strokeColor: AppColors.skyDark,
                            ),
                          ),
                          belowBarData: BarAreaData(
                            show: true,
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                AppColors.sky.withValues(alpha: 0.35),
                                AppColors.sky.withValues(alpha: 0.02),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class BreakdownList extends StatelessWidget {
  const BreakdownList({
    super.key,
    required this.title,
    required this.points,
  });

  final String title;
  final List<ChartPoint> points;

  @override
  Widget build(BuildContext context) {
    final total = points.fold(0.0, (s, p) => s + p.value);
    return OwnerCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: GoogleFonts.cairo(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  color: AppColors.navy)),
          const SizedBox(height: 14),
          if (points.isEmpty)
            Text(tr(context, 'No data in this period'),
                style: GoogleFonts.cairo(color: AppColors.muted))
          else
            for (final p in points.take(5)) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(p.label,
                        style: GoogleFonts.cairo(
                            fontWeight: FontWeight.w600,
                            color: AppColors.navy)),
                  ),
                  Text(p.value.toStringAsFixed(2),
                      style: GoogleFonts.cairo(fontWeight: FontWeight.w800)),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  value: total <= 0 ? 0 : (p.value / total).clamp(0.0, 1.0),
                  minHeight: 8,
                  backgroundColor: const Color(0xFFF1F5F9),
                  color: AppColors.skyDark,
                ),
              ),
              const SizedBox(height: 14),
            ],
        ],
      ),
    );
  }
}

class MetricTile extends StatelessWidget {
  const MetricTile({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.accent = AppColors.skyDark,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return OwnerCard(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 18, color: accent),
          ),
          const SizedBox(height: 14),
          Text(label,
              style: GoogleFonts.cairo(
                  color: AppColors.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.cairo(
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                  color: AppColors.navy,
                  height: 1.15)),
        ],
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: GoogleFonts.cairo(
            fontWeight: FontWeight.w800, fontSize: 16, color: AppColors.navy));
  }
}

class EmptyHint extends StatelessWidget {
  const EmptyHint(this.text, {super.key, this.icon = Icons.inbox_outlined});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: const Color(0xFFE0F2FE),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(icon, color: AppColors.skyDark, size: 28),
            ),
            const SizedBox(height: 14),
            Text(text,
                textAlign: TextAlign.center,
                style: GoogleFonts.cairo(
                    color: AppColors.muted, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

class KvRow extends StatelessWidget {
  const KvRow(this.label, this.value, {super.key, this.emphasize = false});
  final String label;
  final String value;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: GoogleFonts.cairo(
                    color: emphasize ? AppColors.navy : AppColors.muted,
                    fontWeight: emphasize ? FontWeight.w700 : FontWeight.w600,
                    fontSize: emphasize ? 15 : 14)),
          ),
          Text(value,
              style: GoogleFonts.cairo(
                  fontWeight: FontWeight.w800,
                  fontSize: emphasize ? 16 : 14,
                  color: AppColors.navy)),
        ],
      ),
    );
  }
}

class OrderListCard extends StatelessWidget {
  const OrderListCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.amount,
    this.leadingIcon = Icons.receipt_long_rounded,
    this.accent = AppColors.skyDark,
    this.onTap,
  });

  final String title;
  final String subtitle;
  final String amount;
  final IconData leadingIcon;
  final Color accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return OwnerCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(leadingIcon, color: accent, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.cairo(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: AppColors.navy)),
                const SizedBox(height: 2),
                Text(subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.cairo(
                        color: AppColors.muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(amount,
                  style: GoogleFonts.cairo(
                      fontWeight: FontWeight.w800, color: AppColors.navy)),
              if (onTap != null)
                Icon(Icons.chevron_right_rounded,
                    size: 18, color: AppColors.muted.withValues(alpha: 0.7)),
            ],
          ),
        ],
      ),
    );
  }
}
