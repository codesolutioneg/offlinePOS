import 'package:flutter/material.dart';

import '../../core/auth/permissions.dart';
import '../../core/db/settings_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';

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
          _roleHeader(context, tr(context, 'Cashier')),
          _permissionCard('cashier'),
          for (final role in custom) ...[
            const SizedBox(height: 16),
            _roleHeader(context, role, editable: role),
            _permissionCard(role),
          ],
        ],
      ),
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

  Future<void> _addRole() async {
    final name = await _promptName(title: 'Add role');
    if (name == null) return;
    if (!widget.settings.addCustomRole(name)) {
      _say('That role already exists.');
      return;
    }
    widget.onChanged();
    setState(() {});
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

  Widget _roleHeader(BuildContext context, String label, {String? editable}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          // Only a role the shop added can be renamed or removed. Manager and
          // cashier are what the app itself falls back on.
          if (editable != null)
            PopupMenuButton<String>(
              key: Key('role-menu-$editable'),
              onSelected: (v) {
                if (v == 'rename') _renameRole(editable);
                if (v == 'delete') _deleteRole(editable);
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  key: Key('rename-$editable'),
                  value: 'rename',
                  child: Text(tr(context, 'Rename')),
                ),
                PopupMenuItem(
                  key: Key('delete-$editable'),
                  value: 'delete',
                  child: Text(tr(context, 'Delete')),
                ),
              ],
            ),
        ]),
      );
}
