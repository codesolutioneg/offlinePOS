import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../core/onboarding/setup_checklist.dart';
import '../../core/theme/app_colors.dart';

/// What this till still needs, at the top of the settings hub.
///
/// It sits here rather than over the sell screen on purpose: every row that fixes
/// one of these is directly underneath it, and a cashier mid-service can do nothing
/// about any of them. Presentational, like the coach overlay: it is handed the list
/// and reports the dismissal, and the rule about who has seen it lives with the
/// wizard store.
class SetupChecklistCard extends StatelessWidget {
  const SetupChecklistCard({
    super.key,
    required this.checklist,
    required this.onDismiss,
  });

  final SetupChecklist checklist;

  /// "Hide this". Only offered while something is outstanding, because once
  /// everything is done the card takes itself away.
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Card(
        key: const Key('setup-checklist'),
        margin: const EdgeInsets.all(12),
        color: AppColors.info.withValues(alpha: 0.06),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.checklist, color: AppColors.info),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${tr(context, 'Finish setting up this till')} '
                    '(${checklist.steps.length - checklist.remaining}/${checklist.steps.length})',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                TextButton(
                  key: const Key('setup-checklist-hide'),
                  onPressed: onDismiss,
                  child: Text(tr(context, 'Hide')),
                ),
              ]),
              const SizedBox(height: 4),
              // Selling works with none of this done, which is the whole reason a
              // half-finished install goes unnoticed.
              Text(
                tr(context, 'The till already sells. These are what it still needs.'),
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              for (final step in checklist.steps)
                ListTile(
                  key: Key('setup-step-${step.id}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    step.done ? Icons.check_circle : Icons.radio_button_unchecked,
                    color: step.done ? AppColors.success : Colors.grey,
                  ),
                  title: Text(tr(context, step.title)),
                  subtitle: Text(tr(context, step.detail)),
                ),
            ],
          ),
        ),
      );
}
