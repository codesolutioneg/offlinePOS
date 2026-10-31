import 'package:flutter/material.dart';

import '../../core/auth/access.dart';
import '../../core/auth/permissions.dart';
import '../../core/db/settings_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/order.dart' show OrderType, OrderTypeLabel;
import 'access_catalog.dart';
import 'access_rules_screen.dart';

/// Configure what each role may do on its own.
///
/// The manager role is fixed full access, so it is shown as a read-only row: a
/// manager is unrestricted and cannot be locked out of their own till. Every other
/// role has a switch per [Permission]; an unchecked action still works but asks for
/// a manager PIN, which the explainer at the top says out loud.
///
/// A shop is rarely two job titles, so roles beyond cashier can be added here. The
/// storage never cared how many there were: [SettingsStore.permissionsFor] has
/// always taken any role string, and this screen is what makes that reachable.
class RolesPermissionsScreen extends StatefulWidget {
  const RolesPermissionsScreen({
    super.key,
    required this.settings,
    required this.onChanged,
    this.onRoleRenamed,
    this.onRoleDeleted,
    this.staffOnRole,
  });

  final SettingsStore settings;
  final VoidCallback onChanged;

  /// Moves the staff standing on a role that has just been renamed or deleted. The
  /// settings store holds no roster, so without these a rename leaves accounts
  /// pointing at a role that no longer exists, which reads as "no permissions at
  /// all" the next time they sign in. A delete hands them back to 'cashier'.
  final void Function(String from, String to)? onRoleRenamed;
  final void Function(String role)? onRoleDeleted;

  /// How many active staff are on a role, so deleting one can say who it affects
  /// before it happens rather than after.
  final int Function(String role)? staffOnRole;

  @override
  State<RolesPermissionsScreen> createState() => _RolesPermissionsScreenState();
}

class _RolesPermissionsScreenState extends State<RolesPermissionsScreen> {
  @override
  Widget build(BuildContext context) {
    final custom = widget.settings.customRoles;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Roles & permissions'))),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add-role'),
        onPressed: _addRole,
        icon: const Icon(Icons.add),
        label: Text(tr(context, 'Add role')),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
        children: [
          Card(
            color: AppColors.info.withValues(alpha: 0.08),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                const Icon(Icons.info_outline, color: AppColors.info),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    tr(context, 'Unchecked actions still work, but ask for a manager PIN first.'),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          _roleHeader(context, tr(context, 'Manager')),
          Card(
            child: ListTile(
              key: const Key('role-manager'),
              leading: const Icon(Icons.verified_user, color: AppColors.success),
              title: Text(tr(context, 'Full access')),
              subtitle: Text(tr(context,
                  'A manager can do everything and cannot be restricted.')),
            ),
          ),
          const SizedBox(height: 16),
          _roleHeader(context, tr(context, 'Levels')),
          _levelCard('cashier', tr(context, 'Cashier')),
          for (final role in custom) _levelCard(role, role, editable: true),
        ],
      ),
    );
  }


  /// One level on the list: what it holds at a glance, and the door to its page.
  Widget _levelCard(String role, String label, {bool editable = false}) {
    final s = widget.settings;
    final ids = [for (final g in accessGroups) ...g.items.map((i) => i.id)];
    final gated =
        ids.where((id) => s.accessFor(role, id) == AccessRule.manager).length;
    final hidden =
        ids.where((id) => s.accessFor(role, id) == AccessRule.hidden).length;
    return Card(
      child: ListTile(
        key: Key('level-$role'),
        leading: CircleAvatar(
          backgroundColor: const Color(0xFF1565C0).withValues(alpha: 0.12),
          child: const Icon(Icons.admin_panel_settings, color: Color(0xFF1565C0)),
        ),
        title: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(
          '${tr(context, 'Permissions')}: ${s.permissionsFor(role).length}/${Permission.values.length}'
          '  ·  ${tr(context, 'Order types')}: ${s.orderTypesFor(role).length}'
          '  ·  ${tr(context, 'Manager')}: $gated'
          '  ·  ${tr(context, 'Hidden')}: $hidden',
        ),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (editable) _roleMenu(role),
          const Icon(Icons.chevron_right),
        ]),
        onTap: () => _openLevel(role, label),
      ),
    );
  }

  Future<void> _openLevel(String role, String label) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _LevelScreen(
        settings: widget.settings,
        role: role,
        label: label,
        onChanged: widget.onChanged,
      ),
    ));
    if (mounted) setState(() {});
  }

  Future<void> _addRole() async {
    final name = await _promptName(title: 'Add role');
    if (name == null) return;
    if (!widget.settings.addCustomRole(name)) {
      _say('That role already exists.');
      return;
    }
    widget.onChanged();
    setState(() {});
    final role = SettingsStore.normaliseRole(name);
    await _openLevel(role, role);
  }

  Future<void> _renameRole(String role) async {
    final name = await _promptName(title: 'Rename role', initial: role);
    if (name == null || name == role) return;
    if (!widget.settings.renameCustomRole(role, name)) {
      _say('That role already exists.');
      return;
    }
    // The roster still says the old name, so the staff move with it.
    widget.onRoleRenamed?.call(role, SettingsStore.normaliseRole(name));
    widget.onChanged();
    setState(() {});
  }

  Future<void> _deleteRole(String role) async {
    final on = widget.staffOnRole?.call(role) ?? 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('delete-role'),
        title: Text('${tr(ctx, 'Delete role')} $role'),
        content: Text(on == 0
            ? tr(ctx, 'Nobody is on this role.')
            : '$on ${tr(ctx, 'staff on this role go back to Cashier.')}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr(ctx, 'Cancel')),
          ),
          FilledButton(
            key: const Key('delete-role-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr(ctx, 'Delete')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    widget.settings.deleteCustomRole(role);
    // Before the screen redraws: an account left on a deleted role would have no
    // permissions at all and no way back except a manager noticing.
    widget.onRoleDeleted?.call(role);
    widget.onChanged();
    setState(() {});
  }

  Future<String?> _promptName({required String title, String? initial}) {
    final ctrl = TextEditingController(text: initial ?? '');
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('role-name'),
        title: Text(tr(ctx, title)),
        content: TextField(
          key: const Key('role-name-field'),
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: tr(ctx, 'Role name')),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim().isEmpty ? null : v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr(ctx, 'Cancel')),
          ),
          FilledButton(
            key: const Key('role-name-save'),
            onPressed: () {
              final v = ctrl.text.trim();
              Navigator.pop(ctx, v.isEmpty ? null : v);
            },
            child: Text(tr(ctx, 'Save')),
          ),
        ],
      ),
    );
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      key: const Key('role-message'),
      content: Text(tr(context, message)),
    ));
  }

  Widget _roleHeader(BuildContext context, String label) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 16,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );

  /// Only a level the shop added can be renamed or removed. Manager and cashier
  /// are what the app itself falls back on.
  Widget _roleMenu(String role) => PopupMenuButton<String>(
        key: Key('role-menu-$role'),
        onSelected: (v) {
          if (v == 'rename') _renameRole(role);
          if (v == 'delete') _deleteRole(role);
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            key: Key('rename-$role'),
            value: 'rename',
            child: Text(tr(context, 'Rename')),
          ),
          PopupMenuItem(
            key: Key('delete-$role'),
            value: 'delete',
            child: Text(tr(context, 'Delete')),
          ),
        ],
      );
}

/// One level's page: what it sees (screens and buttons), what sales it may open,
/// and what it may do without a manager.
class _LevelScreen extends StatefulWidget {
  const _LevelScreen({
    required this.settings,
    required this.role,
    required this.label,
    required this.onChanged,
  });

  final SettingsStore settings;
  final String role;
  final String label;
  final VoidCallback onChanged;

  @override
  State<_LevelScreen> createState() => _LevelScreenState();
}

class _LevelScreenState extends State<_LevelScreen> {
  @override
  Widget build(BuildContext context) {
    final role = widget.role;
    return Scaffold(
      key: Key('level-page-$role'),
      appBar: AppBar(title: Text(widget.label)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          _accessCard(role, widget.label),
          const SizedBox(height: 12),
          _orderTypesCard(role),
          const SizedBox(height: 12),
          Card(
            color: AppColors.info.withValues(alpha: 0.08),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                tr(context, 'Unchecked actions still work, but ask for a manager PIN first.'),
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ),
          _permissionCard(role),
        ],
      ),
    );
  }

  /// The door to what this level sees: every screen and button, allowed, behind
  /// a manager, or hidden.
  Widget _accessCard(String role, String label) {
    final ids = [
      for (final g in accessGroups) ...g.items.map((i) => i.id),
    ];
    final gated = ids
        .where((id) => widget.settings.accessFor(role, id) == AccessRule.manager)
        .length;
    final hidden = ids
        .where((id) => widget.settings.accessFor(role, id) == AccessRule.hidden)
        .length;
    return Card(
      color: const Color(0xFF1565C0).withValues(alpha: 0.06),
      child: ListTile(
        key: Key('access-open-$role'),
        leading: const Icon(Icons.admin_panel_settings, color: Color(0xFF1565C0)),
        title: Text(tr(context, 'Screens & buttons'),
            style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text('${tr(context, 'Manager')}: $gated'
            '  ·  ${tr(context, 'Hidden')}: $hidden'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => AccessRulesScreen(
              settings: widget.settings,
              role: role,
              roleLabel: label,
              onChanged: widget.onChanged,
            ),
          ));
          if (mounted) setState(() {});
        },
      ),
    );
  }

  /// Which sales a role may open. Not a permission: there is no manager PIN that
  /// makes a delivery desk into a dining room, so a type that is off is simply not
  /// offered rather than asked for. Per role, because a shop that invented a runner
  /// wants to answer this for the runner too.
  Widget _orderTypesCard(String role) {
    final held = widget.settings.orderTypesFor(role);
    return Card(
      child: Column(children: [
        ListTile(
          dense: true,
          title: Text(tr(context, 'Order types this role may open')),
          subtitle: Text(
              tr(context, 'A tab already open on a table can always be settled.')),
        ),
        for (final t in OrderType.values)
          SwitchListTile(
            key: Key(role == 'cashier'
                ? 'order-type-allowed-${t.name}'
                : 'order-type-allowed-$role-${t.name}'),
            value: held.contains(t),
            title: Text(tr(context, t.label)),
            onChanged: (v) {
              widget.settings.setRoleOrderType(role, t, v);
              widget.onChanged();
              setState(() {});
            },
          ),
      ]),
    );
  }

  /// The switches for one role. Keys carry the role so two roles on the same
  /// screen never share a widget key.
  Widget _permissionCard(String role) {
    final held = widget.settings.permissionsFor(role);
    return Card(
      child: Column(children: [
        for (final p in Permission.values)
          SwitchListTile(
            key: Key(role == 'cashier' ? 'perm-${p.key}' : 'perm-$role-${p.key}'),
            value: held.contains(p),
            title: Text(tr(context, p.label)),
            subtitle: Text(tr(context, p.description)),
            onChanged: (v) {
              widget.settings.setRolePermission(role, p, v);
              widget.onChanged();
              setState(() {});
            },
          ),
      ]),
    );
  }

}