import 'package:flutter/material.dart';

import '../../../core/i18n/l10n.dart';
import '../../../core/theme/app_colors.dart';
import '../../../domain/order.dart';
import '../stress_note.dart';
import 'stress_trace.dart';

/// One order of a full-day run: a line saying what it was and how it ended, that
/// opens on everything that happened to it, step by step.
class StressDayOrderTile extends StatelessWidget {
  const StressDayOrderTile({super.key, required this.trace});

  final OrderTrace trace;

  String _say(BuildContext context, StressNote n) =>
      n.fill(tr(context, n.template));

  @override
  Widget build(BuildContext context) {
    final t = trace;
    final bad = t.hasProblems;
    final where = t.table ?? (t.type == null ? '' : tr(context, t.type!.label));
    return Card(
      child: ExpansionTile(
        key: PageStorageKey<String>('stress-day-${t.index}'),
        leading: Icon(
          bad ? Icons.warning_amber_rounded : Icons.check_circle,
          color: bad ? AppColors.error : AppColors.success,
        ),
        title: Text(
          '${t.index}. ${tr(context, t.scenario)} · #${t.orderNo ?? '-'} · $where',
        ),
        subtitle: Text(
          '${t.cashier} · ${t.duration.inMilliseconds} ms · '
          '${t.events.length} ${tr(context, 'steps')}',
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (t.error != null)
            Text(
              '${tr(context, 'Stopped')}: ${t.error}',
              style: const TextStyle(color: AppColors.error),
            ),
          for (final p in t.problems)
            Text(
              '• ${_say(context, p)}',
              style: TextStyle(color: p.alarm ? AppColors.error : null),
            ),
          const Divider(),
          for (final e in t.events) _EventRow(event: e),
        ],
      ),
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event});

  final TraceEvent event;

  @override
  Widget build(BuildContext context) {
    final e = event;
    final where = e.where == null ? '' : ' → ${e.where}';
    final detail = e.detail.isEmpty ? '' : ' (${e.detail})';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(
        '${e.at.toIso8601String().substring(11, 23)}  ${tr(context, e.step)}$where$detail'
        ' · ${(e.micros / 1000).toStringAsFixed(1)} ms',
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: e.failed ? AppColors.error : null,
        ),
      ),
    );
  }
}
