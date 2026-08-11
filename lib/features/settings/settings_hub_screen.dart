import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';

/// One entry in the settings hub: a titled row that opens a settings screen.
class SettingsEntry {
  const SettingsEntry({
    required this.title,
    required this.icon,
    required this.onTap,
    this.subtitle,
    this.keyValue,
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final VoidCallback onTap;
  final String? keyValue;
}

/// The settings hub: one place that gathers everything a manager configures, so the
/// sell screen stays about selling and the config lives behind one door rather than
/// scattered across the app.
class SettingsHubScreen extends StatelessWidget {
  const SettingsHubScreen({super.key, required this.entries});

  final List<SettingsEntry> entries;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr(context, 'Settings'))),
        body: ListView.separated(
          itemCount: entries.length,
          separatorBuilder: (context, index) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final e = entries[i];
            return ListTile(
              key: e.keyValue != null ? Key(e.keyValue!) : null,
              leading: Icon(e.icon),
              title: Text(e.title),
              subtitle: e.subtitle != null ? Text(e.subtitle!) : null,
              trailing: const Icon(Icons.chevron_right),
              onTap: e.onTap,
            );
          },
        ),
      );
}
