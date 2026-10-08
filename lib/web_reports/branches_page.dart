import 'package:flutter/material.dart';

import '../core/i18n/l10n.dart';
import 'site_api.dart';
import 'site_widgets.dart';

/// The branches and the tills paired to each, with when each last sent its
/// sales and its backup. The owner adds and renames branches here and makes the
/// code a new till pairs with.
class BranchesPage extends StatefulWidget {
  const BranchesPage({super.key, required this.api, required this.canManage});

  final SiteApi api;
  final bool canManage;

  @override
  State<BranchesPage> createState() => _BranchesPageState();
}

class _BranchesPageState extends State<BranchesPage> {
  List<SiteBranch>? _branches;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final branches = await widget.api.branches();
      if (mounted) setState(() => _branches = branches);
    } catch (e) {
      if (mounted) showSiteError(context, e);
    }
  }

  Future<void> _showCode(String branch, String code) => showSecretDialog(
        context,
        '${tr(context, 'Pairing code')} — $branch',
        tr(context,
            'On the till: Settings, Cloud backup, then enter this code. Every till of this branch can use it until a new one is made.'),
        code,
      );

  Future<void> _add() async {
    final name = await askText(context, tr(context, 'New branch'), tr(context, 'Name'));
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final made = await widget.api.addBranch(name);
      await _load();
      if (mounted) await _showCode(made.branch.name, made.pairCode);
    } catch (e) {
      if (mounted) showSiteError(context, e);
    }
  }

  Future<void> _rename(SiteBranch b) async {
    final name = await askText(context, tr(context, 'Rename branch'), tr(context, 'Name'),
        initial: b.name);
    if (name == null || name.isEmpty || name == b.name || !mounted) return;
    try {
      await widget.api.renameBranch(b.id, name);
      await _load();
    } catch (e) {
      if (mounted) showSiteError(context, e);
    }
  }

  Future<void> _newCode(SiteBranch b) async {
    if (!await confirm(context,
        tr(context, 'Make a new pairing code? The old code stops working; tills already paired stay paired.'))) {
      return;
    }
    try {
      final code = await widget.api.newPairCode(b.id);
      if (mounted) await _showCode(b.name, code);
    } catch (e) {
      if (mounted) showSiteError(context, e);
    }
  }

  /// Deletes [b] once the owner has read what goes with it and typed its name.
  Future<void> _delete(SiteBranch b) async {
    if (!await confirm(context,
        '${tr(context, 'Delete branch')} ${b.name}? ${tr(context, 'Its tills are unpaired and every sale, shift and backup they sent is deleted from the server. This cannot be undone.')}')) {
      return;
    }
    if (!mounted) return;
    final typed = await askText(
        context, '${tr(context, 'Delete branch')} ${b.name}', tr(context, 'Type the branch name to confirm'),
        action: 'Delete');
    if (typed == null || !mounted) return;
    if (typed.trim() != b.name.trim()) {
      showSiteError(context, tr(context, 'The name does not match; nothing was deleted.'));
      return;
    }
    try {
      await widget.api.deleteBranch(b.id);
      await _load();
    } catch (e) {
      if (mounted) showSiteError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final branches = _branches;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Branches and tills'))),
      floatingActionButton: widget.canManage
          ? FloatingActionButton.extended(
              key: const Key('branch-add'),
              onPressed: _add,
              icon: const Icon(Icons.add_business),
              label: Text(tr(context, 'New branch')),
            )
          : null,
      body: branches == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
              children: [
                for (final b in branches)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          const Icon(Icons.storefront),
                          const SizedBox(width: 8),
                          Expanded(
                              child: Text(b.name, style: Theme.of(context).textTheme.titleMedium)),
                          if (widget.canManage) ...[
                            TextButton.icon(
                              onPressed: () => _rename(b),
                              icon: const Icon(Icons.edit),
                              label: Text(tr(context, 'Rename')),
                            ),
                            TextButton.icon(
                              key: Key('branch-code-${b.id}'),
                              onPressed: () => _newCode(b),
                              icon: const Icon(Icons.qr_code),
                              label: Text(tr(context, 'New pairing code')),
                            ),
                            if (branches.length > 1)
                              TextButton.icon(
                                key: Key('branch-delete-${b.id}'),
                                onPressed: () => _delete(b),
                                style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
                                icon: const Icon(Icons.delete_outline),
                                label: Text(tr(context, 'Delete')),
                              ),
                          ],
                        ]),
                        const Divider(),
                        if (b.devices.isEmpty)
                          Text(tr(context, 'No till paired yet'))
                        else
                          for (final d in b.devices)
                            ListTile(
                              dense: true,
                              leading: const Icon(Icons.point_of_sale),
                              title: Text(d.name),
                              subtitle: Text([
                                '${tr(context, 'Last sync')}: ${siteWhen(context, d.lastSyncAt)}',
                                '${tr(context, 'Last backup')}: ${siteWhen(context, d.lastBackupAt)}',
                                if (d.appVersion.isNotEmpty) 'v${d.appVersion}',
                              ].join('  ·  ')),
                            ),
                      ]),
                    ),
                  ),
              ],
            ),
    );
  }
}
