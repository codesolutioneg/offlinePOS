import 'package:flutter/material.dart';

import '../core/i18n/l10n.dart';
import '../core/theme/app_colors.dart';
import '../features/reports/report_access.dart';
import 'site_api.dart';
import 'site_widgets.dart';

/// The owner's list of who may sign in to the site, which branches each sees
/// and which reports beyond the sales each may open.
class UsersPage extends StatefulWidget {
  const UsersPage({super.key, required this.api, required this.me});

  final SiteApi api;
  final SiteUser me;

  @override
  State<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends State<UsersPage> {
  List<SiteUser>? _users;
  List<SiteBranch> _branches = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final users = await widget.api.users();
      final branches = await widget.api.branches();
      if (!mounted) return;
      setState(() {
        _users = users;
        _branches = branches;
      });
    } catch (e) {
      if (mounted) showSiteError(context, e);
    }
  }

  Future<void> _edit([SiteUser? user]) async {
    final draft = await showDialog<SiteUserDraft>(
      context: context,
      builder: (_) => _UserDialog(
        user: user,
        branches: _branches,
        isMe: user?.id == widget.me.id,
      ),
    );
    if (draft == null || !mounted) return;
    try {
      if (user == null) {
        final made = await widget.api.addUser(draft);
        if (made.password != null && mounted) {
          await showSecretDialog(
            context,
            '${tr(context, 'Password for')} ${made.user.username}',
            tr(context,
                'Give this password to the user. It is not shown again; they can change it after signing in.'),
            made.password!,
          );
        }
      } else {
        await widget.api.updateUser(user.id, draft);
        if (draft.password != null &&
            draft.password!.isNotEmpty &&
            mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr(context, 'Password changed'))),
          );
        }
      }
      await _load();
    } catch (e) {
      if (mounted) showSiteError(context, e);
    }
  }

  Future<void> _reset(SiteUser user) async {
    if (!await confirm(
      context,
      '${tr(context, 'Make a new password for')} ${user.username}? ${tr(context, 'They are signed out everywhere.')}',
    )) {
      return;
    }
    try {
      final password = await widget.api.resetPassword(user.id);
      if (mounted) {
        await showSecretDialog(
          context,
          '${tr(context, 'Password for')} ${user.username}',
          tr(context,
              'Give this password to the user. It is not shown again; they can change it after signing in.'),
          password,
        );
      }
    } catch (e) {
      if (mounted) showSiteError(context, e);
    }
  }

  Future<void> _delete(SiteUser user) async {
    if (!await confirm(
        context, '${tr(context, 'Delete user')} ${user.username}?')) {
      return;
    }
    try {
      await widget.api.deleteUser(user.id);
      await _load();
    } catch (e) {
      if (mounted) showSiteError(context, e);
    }
  }

  String _scope(BuildContext context, SiteUser u) {
    if (u.allBranches) return tr(context, 'All branches');
    final names = [
      for (final b in _branches)
        if (u.branchIds.contains(b.id)) b.name,
    ];
    return names.isEmpty ? tr(context, 'No branch') : names.join('، ');
  }

  Color _roleColor(SiteRole role) => switch (role) {
        SiteRole.owner => AppColors.brandNavy,
        SiteRole.manager => AppColors.primary,
        SiteRole.accountant => const Color(0xFF0D9488),
      };

  @override
  Widget build(BuildContext context) {
    final users = _users;
    final activeCount = users?.where((u) => u.active).length ?? 0;
    final owners = users?.where((u) => u.role == SiteRole.owner).length ?? 0;

    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F9),
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: AppColors.brandNavy,
        leading: IconButton(
          tooltip: tr(context, 'Back'),
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        title: Text(
          tr(context, 'Users and permissions'),
          style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: -0.2),
        ),
        actions: [
          IconButton(
            tooltip: tr(context, 'Refresh'),
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('user-add'),
        onPressed: users == null ? null : () => _edit(),
        backgroundColor: AppColors.brandNavy,
        foregroundColor: Colors.white,
        elevation: 2,
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: Text(
          tr(context, 'New user'),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFF8FAFC), Color(0xFFEEF2F7)],
          ),
        ),
        child: users == null
            ? const Center(child: CircularProgressIndicator())
            : Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 860),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
                    children: [
                      Text(
                        tr(context,
                            'Who may sign in, which branches they see, and which reports they can open.'),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: AppColors.textSecondaryLight,
                              height: 1.45,
                            ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          _stat(
                            tr(context, 'Users'),
                            '${users.length}',
                            Icons.people_alt_rounded,
                            AppColors.brandNavy,
                          ),
                          const SizedBox(width: 10),
                          _stat(
                            tr(context, 'Active'),
                            '$activeCount',
                            Icons.verified_user_outlined,
                            AppColors.success,
                          ),
                          const SizedBox(width: 10),
                          _stat(
                            tr(context, 'Owners'),
                            '$owners',
                            Icons.shield_outlined,
                            AppColors.primary,
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      for (final u in users) ...[
                        _userCard(u),
                        const SizedBox(height: 10),
                      ],
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  Widget _stat(String label, String value, IconData icon, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE2E8F0)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x080F172A),
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textMutedLight,
                    ),
                  ),
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: color,
                      letterSpacing: -0.4,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _userCard(SiteUser u) {
    final color = _roleColor(u.role);
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        key: Key('user-${u.username}'),
        borderRadius: BorderRadius.circular(16),
        onTap: () => _edit(u),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE2E8F0)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x080F172A),
                blurRadius: 14,
                offset: Offset(0, 5),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: (u.active ? color : AppColors.textMutedLight)
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(
                  u.active ? Icons.person_rounded : Icons.person_off_rounded,
                  color: u.active ? color : AppColors.textMutedLight,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      u.displayName.trim().isEmpty ? u.username : u.displayName,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        color: u.active
                            ? AppColors.brandNavy
                            : AppColors.textMutedLight,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '@${u.username}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textMutedLight,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        _pill(roleLabel(context, u.role), color),
                        _pill(_scope(context, u), AppColors.textSecondaryLight),
                        if (!u.active)
                          _pill(tr(context, 'Disabled'), AppColors.error),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${tr(context, 'Last sign-in')}: ${siteWhen(context, u.lastLoginAt)}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondaryLight,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'edit') _edit(u);
                  if (v == 'reset') _reset(u);
                  if (v == 'delete') _delete(u);
                },
                itemBuilder: (ctx) => [
                  PopupMenuItem(value: 'edit', child: Text(tr(ctx, 'Edit'))),
                  PopupMenuItem(
                      value: 'reset', child: Text(tr(ctx, 'New password'))),
                  if (u.id != widget.me.id)
                    PopupMenuItem(
                        value: 'delete', child: Text(tr(ctx, 'Delete'))),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pill(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

class _UserDialog extends StatefulWidget {
  const _UserDialog({this.user, required this.branches, required this.isMe});

  final SiteUser? user;
  final List<SiteBranch> branches;
  final bool isMe;

  @override
  State<_UserDialog> createState() => _UserDialogState();
}

class _UserDialogState extends State<_UserDialog> {
  late final _username = TextEditingController(text: widget.user?.username ?? '');
  late final _name = TextEditingController(text: widget.user?.displayName ?? '');
  final _password = TextEditingController();
  final _passwordConfirm = TextEditingController();
  var _obscurePassword = true;
  late SiteRole _role = widget.user?.role ?? SiteRole.manager;
  late bool _allBranches = widget.user?.allBranches ?? false;
  late final Set<String> _branchIds = {...?widget.user?.branchIds};
  late Set<String> _caps = {...(widget.user?.capabilities ?? _defaults(SiteRole.manager))};
  late Set<String> _reportKeys = {
    ...(widget.user?.reportKeys ??
        defaultOwnerReportKeys(SiteRole.manager.name)),
  };
  late bool _active = widget.user?.active ?? true;

  bool get _creating => widget.user == null;

  static Set<String> _defaults(SiteRole role) => switch (role) {
        SiteRole.accountant => {'expenses', 'backoffice', 'flash'},
        _ => {...reportCapabilities},
      };

  @override
  void dispose() {
    _username.dispose();
    _name.dispose();
    _password.dispose();
    _passwordConfirm.dispose();
    super.dispose();
  }

  String? _passwordError() {
    final p = _password.text;
    final c = _passwordConfirm.text;
    if (p.isEmpty && c.isEmpty) return null;
    if (p.length < 8) {
      return tr(context, 'Password needs at least 8 characters');
    }
    if (p != c) return tr(context, 'Passwords do not match');
    return null;
  }

  void _pickRole(SiteRole role) => setState(() {
        _role = role;
        if (_creating) {
          _caps = _defaults(role);
          _reportKeys = defaultOwnerReportKeys(role.name);
        }
        if (role == SiteRole.owner) _allBranches = true;
      });

  @override
  Widget build(BuildContext context) {
    final owner = _role == SiteRole.owner;
    return AlertDialog(
      title: Text(_creating ? tr(context, 'New user') : widget.user!.username),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_creating)
                TextField(
                  key: const Key('user-username'),
                  controller: _username,
                  textDirection: TextDirection.ltr,
                  decoration: InputDecoration(
                    labelText: tr(context, 'Username'),
                    helperText: tr(context,
                        'Lowercase letters, digits, dot, dash; 3 to 32'),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: tr(context, 'Username'),
                      helperText: tr(context,
                          'Sign-in uses the username, not the display name.'),
                    ),
                    child: SelectableText(
                      widget.user!.username,
                      textDirection: TextDirection.ltr,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ),
              TextField(
                key: const Key('user-name'),
                controller: _name,
                decoration: InputDecoration(
                  labelText: tr(context, 'Name'),
                  helperText: tr(context, 'Shown in the app; not used to sign in.'),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<SiteRole>(
                key: const Key('user-role'),
                initialValue: _role,
                decoration: InputDecoration(labelText: tr(context, 'Role')),
                items: [
                  for (final r in SiteRole.values)
                    DropdownMenuItem(
                        value: r, child: Text(roleLabel(context, r))),
                ],
                onChanged: widget.isMe ? null : (r) => _pickRole(r ?? _role),
              ),
              const SizedBox(height: 12),
              Text(tr(context, 'Branches'),
                  style: Theme.of(context).textTheme.titleSmall),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr(context, 'All branches')),
                value: owner || _allBranches,
                onChanged: owner ? null : (v) => setState(() => _allBranches = v),
              ),
              if (!owner && !_allBranches)
                for (final b in widget.branches)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(b.name),
                    value: _branchIds.contains(b.id),
                    onChanged: (v) => setState(() =>
                        v == true ? _branchIds.add(b.id) : _branchIds.remove(b.id)),
                  ),
              const SizedBox(height: 8),
              Text(tr(context, 'Can also see'),
                  style: Theme.of(context).textTheme.titleSmall),
              if (owner)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(tr(context, 'The owner sees everything.')),
                )
              else
                for (final c in reportCapabilities)
                  CheckboxListTile(
                    key: Key('user-cap-$c'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(capabilityLabel(context, c)),
                    value: _caps.contains(c),
                    onChanged: (v) => setState(
                        () => v == true ? _caps.add(c) : _caps.remove(c)),
                  ),
              const SizedBox(height: 8),
              Text(tr(context, 'Mobile owner app'),
                  style: Theme.of(context).textTheme.titleSmall),
              if (owner)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(tr(context, 'The owner sees everything.')),
                )
              else
                for (final k in ownerReportKeys)
                  CheckboxListTile(
                    key: Key('user-report-$k'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(ownerReportKeyLabel(context, k)),
                    value: _reportKeys.contains(k),
                    onChanged: (v) => setState(() =>
                        v == true ? _reportKeys.add(k) : _reportKeys.remove(k)),
                  ),
            if (!_creating && !widget.isMe)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr(context, 'Can sign in')),
                value: _active,
                onChanged: (v) => setState(() => _active = v),
              ),
            const SizedBox(height: 12),
            Text(
              tr(context, 'Password'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            TextField(
              key: const Key('user-password'),
              controller: _password,
              obscureText: _obscurePassword,
              textDirection: TextDirection.ltr,
              decoration: InputDecoration(
                labelText: _creating
                    ? tr(context, 'New password (optional)')
                    : tr(context, 'New password'),
                helperText: _creating
                    ? tr(context,
                        'Leave empty to let the server make one and show it once.')
                    : tr(context, 'Leave empty to keep the current password.'),
                suffixIcon: IconButton(
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                  icon: Icon(_obscurePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined),
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('user-password-confirm'),
              controller: _passwordConfirm,
              obscureText: _obscurePassword,
              textDirection: TextDirection.ltr,
              decoration: InputDecoration(
                labelText: tr(context, 'Confirm password'),
              ),
            ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr(context, 'Cancel'))),
        FilledButton(
          key: const Key('user-save'),
          style: FilledButton.styleFrom(backgroundColor: AppColors.brandNavy),
          onPressed: () {
            final err = _passwordError();
            if (err != null) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(err)));
              return;
            }
            final name = _name.text.trim();
            final password = _password.text;
            Navigator.pop(
              context,
              SiteUserDraft(
                username:
                    _creating ? _username.text.trim().toLowerCase() : null,
                displayName: name.isEmpty
                    ? (_creating ? _username.text.trim() : null)
                    : name,
                role: _role,
                password: password.isEmpty ? null : password,
                allBranches: owner || _allBranches,
                branchIds: _branchIds.toList(),
                capabilities: _caps,
                reportKeys: owner ? null : _reportKeys,
                active: _creating ? null : _active,
              ),
            );
          },
          child: Text(tr(context, 'Save')),
        ),
      ],
    );
  }
}
