import 'package:flutter/material.dart';

import '../../core/auth/access.dart';
import '../../core/db/settings_store.dart';
import '../../core/i18n/l10n.dart';
import 'access_catalog.dart';

/// What one level sees: for every screen and button, Allowed, Needs a manager,
/// or Hidden. Saved as it is tapped, like the rest of the roles screen.
class AccessRulesScreen extends StatefulWidget {
  const AccessRulesScreen({
    super.key,
    required this.settings,
    required this.role,
    required this.roleLabel,
    required this.onChanged,
  });

  final SettingsStore settings;
  final String role;
  final String roleLabel;
  final VoidCallback onChanged;

  @override
  State<AccessRulesScreen> createState() => _AccessRulesScreenState();
}

class _AccessRulesScreenState extends State<AccessRulesScreen> {
  static const _look = {
    AccessRule.allow: ('Allowed', Icons.check_circle, Color(0xFF27AE60)),
    AccessRule.manager: ('Manager', Icons.lock, Color(0xFFE67E22)),
    AccessRule.hidden: ('Hidden', Icons.visibility_off, Color(0xFF7F8C8D)),
  };

  void _set(String id, AccessRule rule) {
    widget.settings.setAccess(widget.role, id, rule);
    widget.onChanged();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('access-rules'),
      appBar: AppBar(
        title: Text('${widget.roleLabel} · ${tr(context, 'Screens & buttons')}'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          Card(
            color: const Color(0xFF2980B9).withValues(alpha: 0.08),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(spacing: 16, runSpacing: 6, children: [
                for (final e in _look.entries)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(e.value.$2, color: e.value.$3, size: 18),
                    const SizedBox(width: 6),
                    Text(tr(context, _explain(e.key)),
                        style: const TextStyle(fontSize: 13)),
                  ]),
              ]),
            ),
          ),
          const SizedBox(height: 8),
          for (final (i, g) in accessGroups.indexed)
            Card(
              child: ExpansionTile(
                key: PageStorageKey('access-group-$i'),
                initiallyExpanded: i == 0,
                leading: Icon(g.icon),
                title: Text(tr(context, g.title),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(_summary(context, g.items)),
                trailing: PopupMenuButton<AccessRule>(
                  key: Key('access-all-$i'),
                  tooltip: tr(context, 'Set all'),
                  icon: const Icon(Icons.done_all),
                  onSelected: (rule) {
                    for (final item in g.items) {
                      widget.settings.setAccess(widget.role, item.id, rule);
                    }
                    widget.onChanged();
                    setState(() {});
                  },
                  itemBuilder: (_) => [
                    for (final e in _look.entries)
                      PopupMenuItem(
                        key: Key('access-all-$i-${e.key.name}'),
                        value: e.key,
                        child: Row(children: [
                          Icon(e.value.$2, color: e.value.$3),
                          const SizedBox(width: 8),
                          Text('${tr(context, 'Set all')}: '
                              '${tr(context, e.value.$1)}'),
                        ]),
                      ),
                  ],
                ),
                children: [for (final item in g.items) _row(context, item)],
              ),
            ),
        ],
      ),
    );
  }

  String _explain(AccessRule r) => switch (r) {
        AccessRule.allow => 'Allowed: works as normal',
        AccessRule.manager => 'Manager: asks for a manager PIN',
        AccessRule.hidden => 'Hidden: not shown to this level',
      };

  String _summary(BuildContext context, List<AccessItem> items) {
    var manager = 0, hidden = 0;
    for (final i in items) {
      switch (widget.settings.accessFor(widget.role, i.id)) {
        case AccessRule.manager:
          manager++;
        case AccessRule.hidden:
          hidden++;
        case AccessRule.allow:
          break;
      }
    }
    return '${items.length}  ·  ${tr(context, 'Manager')}: $manager'
        '  ·  ${tr(context, 'Hidden')}: $hidden';
  }

  Widget _row(BuildContext context, AccessItem item) {
    final current = widget.settings.accessFor(widget.role, item.id);
    return ListTile(
      key: Key('access-${item.id}'),
      leading: Icon(item.icon, color: _look[current]!.$3),
      title: Text(tr(context, item.label)),
      trailing: Wrap(spacing: 6, children: [
        for (final e in _look.entries)
          ChoiceChip(
            key: Key('access-${item.id}-${e.key.name}'),
            avatar: Icon(e.value.$2,
                size: 16, color: current == e.key ? Colors.white : e.value.$3),
            label: Text(tr(context, e.value.$1)),
            selected: current == e.key,
            showCheckmark: false,
            selectedColor: e.value.$3,
            labelStyle: TextStyle(
              color: current == e.key ? Colors.white : null,
              fontWeight: FontWeight.w600,
            ),
            onSelected: (_) => _set(item.id, e.key),
          ),
      ]),
    );
  }
}
