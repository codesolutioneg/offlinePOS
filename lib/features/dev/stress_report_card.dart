import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';
import 'latency_stats.dart';
import 'stress_lab_runner.dart';
import 'stress_note.dart';

/// One finished Stress Lab run: what was done, how fast, and what to look at.
class StressReportCard extends StatelessWidget {
  const StressReportCard({super.key, required this.report});

  final StressReport report;

  /// A payment slower than this is one a cashier can feel.
  static const double _slowMs = 50;

  String _say(BuildContext context, StressNote n) => n.fill(tr(context, n.template));

  @override
  Widget build(BuildContext context) {
    final lat = report.latency;
    final slow = lat != null && lat.percentileMs(0.95) > _slowMs;
    final bad = report.failed > 0 || slow || report.notes.any((n) => n.alarm);
    final counts = StressNote('{done} done · {failed} failed',
        {'done': report.done, 'failed': report.failed});
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(bad ? Icons.warning_amber_rounded : Icons.check_circle,
                  color: bad ? AppColors.error : AppColors.success),
              const SizedBox(width: 8),
              Expanded(
                child: Text(tr(context, report.title),
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              Text(_say(context, counts)),
            ]),
            if (lat != null && lat.count > 0) ...[
              const SizedBox(height: 6),
              Text(_say(context, _latencyNote(lat)),
                  style: TextStyle(color: slow ? AppColors.error : null)),
            ],
            for (final n in report.notes)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('• ${_say(context, n)}',
                    style: TextStyle(color: n.alarm ? AppColors.error : null)),
              ),
          ],
        ),
      ),
    );
  }

  static StressNote _latencyNote(LatencyStats lat) => StressNote(
        'Time per operation: avg {avg} ms · p95 {p95} ms · max {max} ms',
        {
          'avg': lat.avgMs.toStringAsFixed(1),
          'p95': lat.percentileMs(0.95).toStringAsFixed(1),
          'max': lat.maxMs.toStringAsFixed(1),
        },
      );
}
