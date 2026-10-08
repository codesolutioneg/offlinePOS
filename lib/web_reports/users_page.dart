import 'package:flutter/material.dart';

import '../core/i18n/l10n.dart';
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
      builder: (_) => _UserDialog(user: user, branches: _branches, isMe: user?.id == widget.me.id),
    );
    if (draft == null || !mounted) return;
    try {
      if (user == null) {
        final made = await widget.api.addUser(draft);
        if (made.password != null && mounted) {
          await showSecretDialog(
            context,
            '${tr(context, 'Password for')} ${made.user.username}',
            tr(context, 'Give this password to the user. It is not shown again; they can change it after signing in.'),
            made.password!,
          );
        }
      } else {
        await widget.api.updateUser(user.id, draft);
      }
      await _load();
    } catch (e) {
      if (mounted) showSiteError(context, e);
    }
  }

  Future<void> _reset(SiteUser user) async {
    if (!await confirm(context,
        '${tr(context, 'Make a new password for')} ${user.username}? ${tr(context, 'They are signed out everywhere.')}')) {
      return;
    }
    try {
      final password = await widget.api.resetPassword(user.id);
      if (mounted) {
        await showSecretDialog(
          context,
          '${tr(context, 'Password for')} ${user.username}',
          tr(context, 'Give this password to the user. It is not shown again; they can change it after signing in.'),
          password,
        );
      }
    } catch (e) {
      if (mounted) showSiteError(context, e);
    }
  }

  Future<void> _delete(SiteUser user) async {
    if (!await confirm(context, '${tr(context, 'Delete user')} ${user.username}?')) return;
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
        if (u.branchIds.contains(b.id)) b.name
    ];
    return names.isEmpty ? tr(context, 'No branch') : names.join('، ');
  }

  @override
  Widget build(BuildContext context) {
    final users = _users;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Users and permissions'))),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('user-add'),
        onPressed: users == null ? null : () => _edit(),
        icon: const Icon(Icons.person_add),
        label: Text(tr(context, 'New user')),
      ),
      body: users == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
              children: [
                for (final u in users)
                  Card(
                    child: ListTile(
                      key: Key('user-${u.username}'),
                      leading: Icon(u.active ? Icons.person : Icons.person_off,
                          color: u.active ? null : Theme.of(context).disabledColor),
                      title: Text('${u.displayName}  (${u.username})'),
                      subtitle: Text([
                        roleLabel(context, u.role),
                        _scope(context, u),
                        if (!u.active) tr(context, 'Disabled'),
                        '${tr(context, 'Last sign-in')}: ${siteWhen(context, u.lastLoginAt)}',
                      ].join('  ·  ')),
                      onTap: () => _edit(u),
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) {
                          if (v == 'edit') _edit(u);
                          if (v == 'reset') _reset(u);
                          if (v == 'delete') _delete(u);
                        },
                        itemBuilder: (ctx) => [
                          PopupMenuItem(value: 'edit', child: Text(tr(ctx, 'Edit'))),
                          PopupMenuItem(value: 'reset', child: Text(tr(ctx, 'New password'))),
                          if (u.id != widget.me.id)
                            PopupMenuItem(value: 'delete', child: Text(tr(ctx, 'Delete'))),
                        ],
                      ),
                    ),
                  ),
              ],
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
  late SiteRole _role = widget.user?.role ?? SiteRole.manager;
  late bool _allBranches = widget.user?.allBranches ?? false;
  late final Set<String> _branchIds = {...?widget.user?.branchIds};
  late Set<String> _caps = {...(widget.user?.capabilities ?? _defaults(SiteRole.manager))};
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
    super.dispose();
  }

  void _pickRole(SiteRole role) => setState(() {
        _role = role;
        // A new account starts from what its role usually gets.
        if (_creating) _caps = _defaults(role);
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
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            if (_creating)
              TextField(
                key: const Key('user-username'),
                controller: _username,
                textDirection: TextDirection.ltr,
                decoration: InputDecoration(
                    labelText: tr(context, 'Username'),
                    helperText: tr(context, 'Lowercase letters, digits, dot, dash; 3 to 32')),
              ),
            TextField(
              key: const Key('user-name'),
              controller: _name,
              decoration: InputDecoration(labelText: tr(context, 'Name')),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<SiteRole>(
              key: const Key('user-role'),
              initialValue: _role,
              decoration: InputDecoration(labelText: tr(context, 'Role')),
              items: [
                for (final r in SiteRole.values)
                  DropdownMenuItem(value: r, child: Text(roleLabel(context, r))),
              ],
              onChanged: widget.isMe ? null : (r) => _pickRole(r ?? _role),
            ),
            const SizedBox(height: 12),
            Text(tr(context, 'Branches'), style: Theme.of(context).textTheme.titleSmall),
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
                  onChanged: (v) => setState(() => v == true ? _branchIds.add(b.id) : _branchIds.remove(b.id)),
                ),
            const SizedBox(height: 8),
            Text(tr(context, 'Can also see'), style: Theme.of(context).textTheme.titleSmall),
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
                  onChanged: (v) => setState(() => v == true ? _caps.add(c) : _caps.remove(c)),
                ),
            if (!_creating && !widget.isMe)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr(context, 'Can sign in')),
                value: _active,
                onChanged: (v) => setState(() => _active = v),
              ),
            if (_creating)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(tr(context, 'A password is made for the new user and shown once.')),
              ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr(context, 'Cancel'))),
        FilledButton(
          key: const Key('user-save'),
          onPressed: () {
            final name = _name.text.trim();
            Navigator.pop(
              context,
              SiteUserDraft(
                username: _creating ? _username.text.trim().toLowerCase() : null,
                displayName: name.isEmpty ? (_creating ? _username.text.trim() : null) : name,
                role: _role,
                allBranches: owner || _allBranches,
                branchIds: _branchIds.toList(),
                capabilities: _caps,
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
