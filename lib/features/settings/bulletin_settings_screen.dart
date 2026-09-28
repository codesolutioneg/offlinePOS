import 'package:flutter/material.dart';

import '../../core/db/settings_store.dart';
import '../../core/i18n/l10n.dart';
import '../tables/floor_action_bar.dart';
import '../sell/order_actions.dart';
import '../tables/floor_bulletin_panel.dart';

/// What the tables screen shows: the Bulletin board and its rows, and the button
/// bar along the bottom and its buttons. Saved as each switch is flipped, so the
/// floor reads the change the moment it is back.
class BulletinSettingsScreen extends StatefulWidget {
  const BulletinSettingsScreen({
    super.key,
    required this.settings,
    required this.onChanged,
  });

  final SettingsStore settings;
  final VoidCallback onChanged;

  @override
  State<BulletinSettingsScreen> createState() => _BulletinSettingsScreenState();
}

class _BulletinSettingsScreenState extends State<BulletinSettingsScreen> {
  late bool _bulletin = widget.settings.floorBulletinEnabled;
  late Set<String> _rowsHidden = widget.settings.floorBulletinHidden;
  late bool _bar = widget.settings.floorActionBarEnabled;
  late Set<String> _buttonsHidden = widget.settings.floorActionsHidden;
  late bool _orderBar = widget.settings.orderActionBarEnabled;
  late Set<String> _orderHidden = widget.settings.orderActionsHidden;

  void _save(VoidCallback write) {
    setState(write);
    widget.settings
      ..floorBulletinEnabled = _bulletin
      ..floorBulletinHidden = _rowsHidden
      ..floorActionBarEnabled = _bar
      ..floorActionsHidden = _buttonsHidden
      ..orderActionBarEnabled = _orderBar
      ..orderActionsHidden = _orderHidden;
    widget.onChanged();
  }

  static Set<String> _toggled(Set<String> hidden, String id, bool show) =>
      show ? ({...hidden}..remove(id)) : {...hidden, id};

  Widget _swatch(IconData icon, Color color) => Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, color: Colors.white, size: 18),
      );

  @override
  Widget build(BuildContext context) {
    final heading = Theme.of(context).textTheme.titleSmall;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Floor screen'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            key: const Key('bulletin-enabled'),
            contentPadding: EdgeInsets.zero,
            title: Text(tr(context, 'Show the bulletin on the floor'),
                style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(tr(context,
                'Live numbers down the right of the tables screen')),
            value: _bulletin,
            onChanged: (v) => _save(() => _bulletin = v),
          ),
          Text(tr(context, 'What it shows'), style: heading),
          for (final r in FloorBulletinPanel.rows)
            SwitchListTile(
              key: Key('bulletin-row-${r.id}'),
              contentPadding: EdgeInsets.zero,
              secondary: _swatch(r.icon, r.color),
              title: Text(tr(context, r.label)),
              value: !_rowsHidden.contains(r.id),
              onChanged: _bulletin
                  ? (v) => _save(
                      () => _rowsHidden = _toggled(_rowsHidden, r.id, v))
                  : null,
            ),
          const Divider(height: 32),
          SwitchListTile(
            key: const Key('action-bar-enabled'),
            contentPadding: EdgeInsets.zero,
            title: Text(tr(context, 'Show the button bar'),
                style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(tr(context,
                'The coloured buttons along the bottom of the tables screen')),
            value: _bar,
            onChanged: (v) => _save(() => _bar = v),
          ),
          Text(tr(context, 'Buttons'), style: heading),
          for (final a in FloorActionBar.catalog)
            SwitchListTile(
              key: Key('action-button-${a.id}'),
              contentPadding: EdgeInsets.zero,
              secondary: _swatch(a.icon, a.color),
              title: Text(tr(context, a.label)),
              value: !_buttonsHidden.contains(a.id),
              onChanged: _bar
                  ? (v) => _save(
                      () => _buttonsHidden = _toggled(_buttonsHidden, a.id, v))
                  : null,
            ),
          const Divider(height: 32),
          SwitchListTile(
            key: const Key('order-bar-enabled'),
            contentPadding: EdgeInsets.zero,
            title: Text(tr(context, 'Show the order screen button bar'),
                style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(tr(context,
                'The coloured buttons along the bottom of the order screen')),
            value: _orderBar,
            onChanged: (v) => _save(() => _orderBar = v),
          ),
          Text(tr(context, 'Buttons'), style: heading),
          for (final a in orderActionCatalog)
            SwitchListTile(
              key: Key('order-button-${a.id}'),
              contentPadding: EdgeInsets.zero,
              secondary: _swatch(a.icon, a.color),
              title: Text(tr(context, a.label)),
              value: !_orderHidden.contains(a.id),
              onChanged: _orderBar
                  ? (v) => _save(
                      () => _orderHidden = _toggled(_orderHidden, a.id, v))
                  : null,
            ),
        ],
      ),
    );
  }
}
