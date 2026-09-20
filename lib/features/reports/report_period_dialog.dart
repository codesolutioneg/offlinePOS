import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';

/// Preset windows offered when opening a single report.
enum ReportRange { openShift, today, yesterday, last7, all }

extension ReportRangeLabel on ReportRange {
  String label(BuildContext context) => switch (this) {
        ReportRange.openShift => tr(context, 'Current shift'),
        ReportRange.today => tr(context, 'Today'),
        ReportRange.yesterday => tr(context, 'Yesterday'),
        ReportRange.last7 => tr(context, 'Last 7 days'),
        ReportRange.all => tr(context, 'All'),
      };
}

/// Period the manager picked for **one** report (Dishflow: report first, then period).
class ReportPeriodChoice {
  const ReportPeriodChoice._({
    required this.label,
    this.range,
    this.custom,
  });

  factory ReportPeriodChoice.preset(ReportRange range, String label) =>
      ReportPeriodChoice._(label: label, range: range);

  factory ReportPeriodChoice.customRange(DateTimeRange custom, String label) =>
      ReportPeriodChoice._(label: label, custom: custom);

  final String label;
  final ReportRange? range;
  final DateTimeRange? custom;
}

/// Ask for the report window after the report was chosen — not a hub-wide filter.
Future<ReportPeriodChoice?> showReportPeriodDialog(
  BuildContext context, {
  String? title,
  DateTime? shiftOpenedAt,
}) {
  return showDialog<ReportPeriodChoice>(
    context: context,
    builder: (ctx) => _ReportPeriodDialog(
      title: title ?? tr(ctx, 'Select period'),
      shiftOpenedAt: shiftOpenedAt,
    ),
  );
}

class _ReportPeriodDialog extends StatelessWidget {
  const _ReportPeriodDialog({
    required this.title,
    this.shiftOpenedAt,
  });

  final String title;
  final DateTime? shiftOpenedAt;

  @override
  Widget build(BuildContext context) {
    final options = <(ReportRange, IconData)>[
      if (shiftOpenedAt != null)
        (ReportRange.openShift, Icons.timelapse),
      (ReportRange.today, Icons.today),
      (ReportRange.yesterday, Icons.history),
      (ReportRange.last7, Icons.date_range),
      (ReportRange.all, Icons.all_inclusive),
    ];

    return AlertDialog(
      key: const Key('report-period-dialog'),
      title: Text(title),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (range, icon) in options)
              ListTile(
                key: Key('period-${range.name}'),
                leading: Icon(icon, color: AppColors.primary),
                title: Text(range.label(context)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                onTap: () => Navigator.pop(
                  context,
                  ReportPeriodChoice.preset(range, range.label(context)),
                ),
              ),
            ListTile(
              key: const Key('period-custom'),
              leading:
                  const Icon(Icons.calendar_month, color: AppColors.primary),
              title: Text(tr(context, 'Custom')),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              onTap: () async {
                final now = DateTime.now();
                final picked = await showDateRangePicker(
                  context: context,
                  firstDate: DateTime(now.year - 2),
                  lastDate: now,
                  initialDateRange: DateTimeRange(
                    start: DateTime(now.year, now.month, now.day),
                    end: DateTime(now.year, now.month, now.day),
                  ),
                );
                if (!context.mounted || picked == null) return;
                String d(DateTime x) {
                  final l = x.toLocal();
                  String two(int n) => n.toString().padLeft(2, '0');
                  return '${l.year}-${two(l.month)}-${two(l.day)}';
                }

                Navigator.pop(
                  context,
                  ReportPeriodChoice.customRange(
                    picked,
                    '${d(picked.start)} → ${d(picked.end)}',
                  ),
                );
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr(context, 'Cancel')),
        ),
      ],
    );
  }
}
