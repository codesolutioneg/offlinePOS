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
    this.group,
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final VoidCallback onTap;
  final String? keyValue;

  /// Section this entry belongs to, e.g. 'Shop' or 'Hardware'. Entries sharing a
  /// group are drawn together under one header; null means no header at all.
  final String? group;
}

/// The settings hub: one place that gathers everything a manager configures, so the
/// sell screen stays about selling and the config lives behind one door rather than
/// scattered across the app.
class SettingsHubScreen extends StatelessWidget {
  const SettingsHubScreen({super.key, required this.entries});

  final List<SettingsEntry> entries;

  @override
  Widget build(BuildContext context) {
    final sections = _sections();
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Settings'))),
      body: ListView(
        children: [
          for (var i = 0; i < sections.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            if (sections[i].title != null)
              _SectionHeader(
                title: sections[i].title!,
                // The first entry's icon stands for its section, so a new group
                // needs no icon table here to keep working.
                icon: sections[i].entries.first.icon,
              ),
            for (final e in sections[i].entries) _tile(context, e),
          ],
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, SettingsEntry e) => ListTile(
        key: e.keyValue != null ? Key(e.keyValue!) : null,
        leading: Icon(e.icon),
        title: Text(tr(context, e.title)),
        subtitle: e.subtitle != null ? Text(tr(context, e.subtitle!)) : null,
        trailing: const Icon(Icons.chevron_right),
        onTap: e.onTap,
      );

  /// Entries bucketed by group: groups in first-appearance order, and any
  /// ungrouped entries leading the list so they are not buried under a header
  /// they do not belong to.
  List<_Section> _sections() {
    final ungrouped = <SettingsEntry>[];
    final groups = <String, List<SettingsEntry>>{};
    for (final e in entries) {
      final group = e.group;
      if (group == null) {
        ungrouped.add(e);
      } else {
        groups.putIfAbsent(group, () => <SettingsEntry>[]).add(e);
      }
    }
    return [
      if (ungrouped.isNotEmpty) _Section(null, ungrouped),
      for (final g in groups.entries) _Section(g.key, g.value),
    ];
  }
}

class _Section {
  const _Section(this.title, this.entries);
  final String? title;
  final List<SettingsEntry> entries;
}

/// A group header: bold, coloured, with a small icon, so the hub reads as a few
/// short lists rather than one long one.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.icon});

  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      key: Key('set-group-$title'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            tr(context, title),
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
