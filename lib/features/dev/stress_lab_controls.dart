import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';

/// The banner that keeps a lab run from being mistaken for a trading day.
class StressLabWarning extends StatelessWidget {
  const StressLabWarning({super.key});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        color: AppColors.warning.withValues(alpha: 0.18),
        padding: const EdgeInsets.all(10),
        child: Text(tr(context, kStressWarning)),
      );
}

/// The warning's English source, which is also its translation key.
const String kStressWarning =
    'Test bench only. Lab orders are real rows on this till '
    'but never leave it: Odoo and Dishflow skip them. Press "Clean up" before '
    'closing the shift; the close is refused while any are left.';

/// The inputs and run buttons of the Stress Lab.
class StressLabControls extends StatelessWidget {
  const StressLabControls({
    super.key,
    required this.count,
    required this.seconds,
    required this.history,
    required this.enabled,
    required this.printing,
    required this.onPrintingChanged,
    required this.onFlood,
    required this.onFill,
    required this.onSettle,
    required this.onGrow,
    required this.onCleanup,
  });

  final TextEditingController count;
  final TextEditingController seconds;
  final TextEditingController history;
  final bool enabled;

  /// Null when this till has no printing path wired (the switch is hidden).
  final bool? printing;
  final ValueChanged<bool> onPrintingChanged;
  final VoidCallback onFlood;
  final VoidCallback onFill;
  final VoidCallback onSettle;
  final VoidCallback onGrow;
  final VoidCallback onCleanup;

  Widget _field(TextEditingController c, String label, Key key) => SizedBox(
        width: 110,
        child: TextField(
          key: key,
          controller: c,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: label, isDense: true),
        ),
      );

  Widget _button(String label, IconData icon, VoidCallback onTap, Key key) =>
      FilledButton.icon(
        key: key,
        onPressed: enabled ? onTap : null,
        icon: Icon(icon),
        label: Text(label),
      );

  @override
  Widget build(BuildContext context) {
    String t(String en) => tr(context, en);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (printing != null)
            FilterChip(
              key: const Key('stress-print'),
              avatar: const Icon(Icons.print),
              label: Text(t('Print to the kitchen and receipt printers')),
              selected: printing ?? false,
              onSelected: enabled ? onPrintingChanged : null,
            ),
          _field(count, t('Orders'), const Key('stress-count')),
          _field(seconds, t('Seconds'), const Key('stress-seconds')),
          _button(t('Order flood'), Icons.bolt, onFlood, const Key('stress-flood')),
          _button(t('Fill every table'), Icons.table_restaurant, onFill,
              const Key('stress-fill')),
          _button(t('Settle the tables'), Icons.payments, onSettle,
              const Key('stress-settle')),
          _field(history, t('Old sales'), const Key('stress-history')),
          _button(t('Pay on a full till'), Icons.speed, onGrow, const Key('stress-grow')),
          _button(t('Clean up'), Icons.cleaning_services, onCleanup,
              const Key('stress-cleanup')),
        ],
      ),
    );
  }
}
