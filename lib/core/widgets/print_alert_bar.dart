import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../i18n/l10n.dart';
import '../theme/app_colors.dart';

/// A kind of slip that no printer took: the sale or the send went through, the
/// paper did not. One per [kind], so a rush with the printer off is one line that
/// counts up rather than a wall of them.
class PrintAlert {
  const PrintAlert({
    required this.kind,
    required this.title,
    required this.where,
    required this.retry,
    this.count = 1,
    this.detail = heldDetail,
  });

  static const heldDetail =
      'Printer offline. Held, and will print when it is back.';

  /// The English l10n line saying what became of the slip.
  final String detail;

  /// What did not print: `kitchen`, `receipt`, `bill`.
  final String kind;

  /// The English l10n line saying so.
  final String title;

  /// The table or order of the latest one, so the cashier knows which to chase.
  final String where;

  /// How many slips of this kind are waiting.
  final int count;

  /// Try again now. True when nothing of this kind is left waiting.
  final Future<bool> Function() retry;
}

/// The red strip that stays on every screen until each alert is retried through
/// or ignored. A toast would be gone before anybody looked at the printer.
class PrintAlertBar extends StatelessWidget {
  const PrintAlertBar({super.key, required this.alerts, required this.onDismiss});

  final ValueListenable<List<PrintAlert>> alerts;

  /// Take the alert of this kind off the strip.
  final void Function(String kind) onDismiss;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<List<PrintAlert>>(
        valueListenable: alerts,
        builder: (context, items, _) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [for (final a in items) _row(context, a)],
        ),
      );

  Widget _row(BuildContext context, PrintAlert a) {
    final more = a.count > 1 ? ' (+${a.count - 1})' : '';
    return Material(
      key: Key('print-alert-${a.kind}'),
      color: AppColors.error,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        child: Row(children: [
          const Icon(Icons.print_disabled, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${tr(context, a.title)} — ${a.where}$more. '
              '${tr(context, a.detail)}',
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(
            key: Key('print-alert-retry-${a.kind}'),
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            onPressed: () async {
              if (await a.retry()) onDismiss(a.kind);
            },
            child: Text(tr(context, 'Retry')),
          ),
          TextButton(
            key: Key('print-alert-ignore-${a.kind}'),
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            onPressed: () => onDismiss(a.kind),
            child: Text(tr(context, 'Ignore')),
          ),
        ]),
      ),
    );
  }
}
