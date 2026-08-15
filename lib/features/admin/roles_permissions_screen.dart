import 'package:flutter/material.dart';

import '../../core/auth/permissions.dart';
import '../../core/db/settings_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/order.dart' show OrderType, OrderTypeLabel;

/// Configure what each role may do on its own.
///
/// The manager role is fixed full access, so it is shown as a read-only row: a
/// manager is unrestricted and cannot be locked out of their own till. The cashier
/// role has a switch per [Permission]; an unchecked action still works but asks for
/// a manager PIN, which the explainer at the top says out loud.
class RolesPermissionsScreen extends StatefulWidget {
  const RolesPermissionsScreen({super.key, required this.settings, required this.onChanged});

  final SettingsStore settings;
  final VoidCallback onChanged;

  @override
  State<RolesPermissionsScreen> createState() => _RolesPermissionsScreenState();
}

class _RolesPermissionsScreenState extends State<RolesPermissionsScreen> {
  @override
  Widget build(BuildContext context) {
    final cashierPerms = widget.settings.permissionsFor('cashier');
    final cashierTypes = widget.settings.orderTypesFor('cashier');
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Roles & permissions'))),
      body: ListView(
        padding: const EdgeInsets.all(12),
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
          // Which sales this role may open. Not a permission: there is no manager
          // PIN that makes a delivery desk into a dining room, so a type that is
          // off is simply not offered rather than asked for.
          Card(
            child: Column(children: [
              ListTile(
                dense: true,
                title: Text(tr(context, 'Order types this role may open')),
                subtitle: Text(tr(context,
                    'A tab already open on a table can always be settled.')),
              ),
              for (final t in OrderType.values)
                SwitchListTile(
                  key: Key('order-type-allowed-${t.name}'),
                  value: cashierTypes.contains(t),
                  title: Text(tr(context, t.label)),
                  onChanged: (v) {
                    widget.settings.setRoleOrderType('cashier', t, v);
                    widget.onChanged();
                    setState(() {});
                  },
                ),
            ]),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(children: [
              for (final p in Permission.values)
                SwitchListTile(
                  key: Key('perm-${p.key}'),
                  value: cashierPerms.contains(p),
                  title: Text(tr(context, p.label)),
                  subtitle: Text(tr(context, p.description)),
                  onChanged: (v) {
                    widget.settings.setRolePermission('cashier', p, v);
                    widget.onChanged();
                    setState(() {});
                  },
                ),
            ]),
          ),
        ],
      ),
    );
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
}
