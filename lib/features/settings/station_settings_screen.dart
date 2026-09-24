import 'package:flutter/material.dart';

import '../../core/db/settings_store.dart';
import '../../core/i18n/l10n.dart';
import '../../domain/table_section_config.dart';

/// Pick what this PC is for: counter till or delivery station (store-order alerts).
class StationSettingsScreen extends StatefulWidget {
  const StationSettingsScreen({
    super.key,
    required this.settings,
    required this.onChanged,
  });

  final SettingsStore settings;
  final VoidCallback onChanged;

  @override
  State<StationSettingsScreen> createState() => _StationSettingsScreenState();
}

class _StationSettingsScreenState extends State<StationSettingsScreen> {
  void _set(StationType type) {
    widget.settings.stationType = type;
    widget.onChanged();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final type = widget.settings.stationType;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'This device type'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            tr(
              context,
              'Delivery gets sound and banner alerts for new store / app orders. '
                  'Counter stays silent; Store orders is still in the menu on both.',
            ),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          SegmentedButton<StationType>(
            key: const Key('station-type'),
            segments: [
              ButtonSegment(
                value: StationType.counter,
                icon: const Icon(Icons.point_of_sale),
                label: Text(tr(context, 'Counter')),
              ),
              ButtonSegment(
                value: StationType.delivery,
                icon: const Icon(Icons.delivery_dining),
                label: Text(tr(context, 'Delivery station')),
              ),
            ],
            selected: {type},
            onSelectionChanged: (s) {
              if (s.isNotEmpty) _set(s.first);
            },
          ),
          const SizedBox(height: 24),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              type == StationType.delivery
                  ? Icons.notifications_active
                  : Icons.notifications_off_outlined,
            ),
            title: Text(
              type == StationType.delivery
                  ? tr(context, 'Store-order alerts: on')
                  : tr(context, 'Store-order alerts: off'),
            ),
            subtitle: Text(
              type == StationType.delivery
                  ? tr(context, 'This device will beep when a new app order arrives.')
                  : tr(
                      context,
                      'This device will not alert. Open Store orders from the menu if needed.',
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
