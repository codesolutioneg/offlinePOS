import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/i18n/l10n.dart';
import '../core/theme/app_colors.dart';
import 'site_api.dart';
import 'site_widgets.dart';
import 'tax_settings_page.dart';

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
    final name =
        await askText(context, tr(context, 'New branch'), tr(context, 'Name'));
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
    final name = await askText(
      context,
      tr(context, 'Rename branch'),
      tr(context, 'Name'),
      initial: b.name,
    );
    if (name == null || name.isEmpty || name == b.name || !mounted) return;
    try {
      await widget.api.renameBranch(b.id, name);
      await _load();
    } catch (e) {
      if (mounted) showSiteError(context, e);
    }
  }

  Future<void> _newCode(SiteBranch b) async {
    if (!await confirm(
      context,
      tr(context,
          'Make a new pairing code? The old code stops working; tills already paired stay paired.'),
    )) {
      return;
    }
    try {
      final code = await widget.api.newPairCode(b.id);
      if (mounted) await _showCode(b.name, code);
    } catch (e) {
      if (mounted) showSiteError(context, e);
    }
  }

  Future<void> _openTaxLink(SiteBranch b) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TaxSettingsPage(
          api: widget.api,
          branchId: b.id,
          branchName: b.name,
          initialConnectionId:
              b.taxConnectionId.isNotEmpty ? b.taxConnectionId : null,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _delete(SiteBranch b) async {
    if (!await confirm(
      context,
      '${tr(context, 'Delete branch')} ${b.name}? ${tr(context, 'Its tills are unpaired and every sale, shift and backup they sent is deleted from the server. This cannot be undone.')}',
    )) {
      return;
    }
    if (!mounted) return;
    final typed = await askText(
      context,
      '${tr(context, 'Delete branch')} ${b.name}',
      tr(context, 'Type the branch name to confirm'),
      action: 'Delete',
    );
    if (typed == null || !mounted) return;
    if (typed.trim() != b.name.trim()) {
      showSiteError(
        context,
        tr(context, 'The name does not match; nothing was deleted.'),
      );
      return;
    }
    try {
      await widget.api.deleteBranch(b.id);
      await _load();
    } catch (e) {
      if (mounted) showSiteError(context, e);
    }
  }

  String _shortId(String id) {
    final t = id.trim();
    if (t.length <= 12) return t;
    return '${t.substring(0, 8)}…';
  }

  String _deviceTitle(SiteDevice d, int index) {
    final n = d.name.trim();
    final looksUuid = n.contains('-') && n.length >= 32;
    if (looksUuid || n.isEmpty) {
      return '${tr(context, 'Till')} ${index + 1}';
    }
    return n;
  }

  bool _isFresh(DateTime? t) {
    if (t == null) return false;
    return DateTime.now().difference(t.toLocal()) < const Duration(hours: 24);
  }

  @override
  Widget build(BuildContext context) {
    final branches = _branches;
    final tillCount =
        branches?.fold<int>(0, (s, b) => s + b.devices.length) ?? 0;
    final linkedCount = branches?.where((b) => b.hasTaxLink).length ?? 0;

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
          tr(context, 'Branches and tills'),
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
      floatingActionButton: widget.canManage
          ? FloatingActionButton.extended(
              key: const Key('branch-add'),
              onPressed: _add,
              backgroundColor: AppColors.brandNavy,
              foregroundColor: Colors.white,
              elevation: 2,
              icon: const Icon(Icons.add_business_rounded),
              label: Text(
                tr(context, 'New branch'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            )
          : null,
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFF8FAFC), Color(0xFFEEF2F7)],
          ),
        ),
        child: branches == null
            ? const Center(child: CircularProgressIndicator())
            : Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 920),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
                    children: [
                      Text(
                        tr(context,
                            'Branches, pairing codes and how each till is doing'),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: AppColors.textSecondaryLight,
                              height: 1.45,
                            ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          _summaryChip(
                            tr(context, 'Branches'),
                            '${branches.length}',
                            Icons.storefront_rounded,
                            AppColors.primary,
                          ),
                          const SizedBox(width: 10),
                          _summaryChip(
                            tr(context, 'Tills'),
                            '$tillCount',
                            Icons.point_of_sale_rounded,
                            AppColors.brandNavy,
                          ),
                          const SizedBox(width: 10),
                          _summaryChip(
                            tr(context, 'Tax linked'),
                            '$linkedCount',
                            Icons.receipt_long_rounded,
                            AppColors.success,
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      if (branches.isEmpty)
                        _emptyState()
                      else
                        for (final b in branches) ...[
                          _branchCard(b, canDelete: branches.length > 1),
                          const SizedBox(height: 14),
                        ],
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  Widget _summaryChip(
    String label,
    String value,
    IconData icon,
    Color color,
  ) {
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

  Widget _emptyState() {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        children: [
          Icon(Icons.storefront_outlined,
              size: 40, color: AppColors.textMutedLight),
          const SizedBox(height: 12),
          Text(
            tr(context, 'No branches yet'),
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: AppColors.brandNavy,
            ),
          ),
        ],
      ),
    );
  }

  Widget _branchCard(SiteBranch b, {required bool canDelete}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A0F172A),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.storefront_rounded,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        b.name,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: AppColors.brandNavy,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _pill(
                            icon: Icons.point_of_sale_rounded,
                            label:
                                '${b.devices.length} ${tr(context, 'tills')}',
                            color: AppColors.brandNavy,
                          ),
                          _taxPill(b),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (widget.canManage)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _actionChip(
                    icon: Icons.receipt_long_outlined,
                    label: tr(context, 'Tax link'),
                    onTap: () => _openTaxLink(b),
                    filled: true,
                  ),
                  _actionChip(
                    icon: Icons.qr_code_rounded,
                    label: tr(context, 'New pairing code'),
                    onTap: () => _newCode(b),
                    key: Key('branch-code-${b.id}'),
                  ),
                  _actionChip(
                    icon: Icons.edit_rounded,
                    label: tr(context, 'Rename'),
                    onTap: () => _rename(b),
                  ),
                  if (canDelete)
                    _actionChip(
                      icon: Icons.delete_outline_rounded,
                      label: tr(context, 'Delete'),
                      onTap: () => _delete(b),
                      danger: true,
                      key: Key('branch-delete-${b.id}'),
                    ),
                ],
              ),
            ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            decoration: const BoxDecoration(
              color: Color(0xFFF8FAFC),
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(18)),
              border: Border(top: BorderSide(color: Color(0xFFF1F5F9))),
            ),
            child: b.devices.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      children: [
                        Icon(
                          Icons.link_off_rounded,
                          size: 18,
                          color: AppColors.textMutedLight,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          tr(context, 'No till paired yet'),
                          style: const TextStyle(
                            color: AppColors.textMutedLight,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  )
                : Column(
                    children: [
                      for (var i = 0; i < b.devices.length; i++) ...[
                        if (i > 0) const SizedBox(height: 8),
                        _deviceRow(b.devices[i], i),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _taxPill(SiteBranch b) {
    if (!b.hasTaxLink) {
      return _pill(
        icon: Icons.link_off_rounded,
        label: tr(context, 'Tax not linked yet'),
        color: AppColors.textMutedLight,
      );
    }
    return InkWell(
      onTap: () {
        Clipboard.setData(ClipboardData(text: b.taxConnectionId));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(context, 'Copied'))),
        );
      },
      borderRadius: BorderRadius.circular(999),
      child: _pill(
        icon: Icons.verified_rounded,
        label: '${tr(context, 'Tax linked')} · ${_shortId(b.taxConnectionId)}',
        color: AppColors.success,
      ),
    );
  }

  Widget _pill({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionChip({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool filled = false,
    bool danger = false,
    Key? key,
  }) {
    final color = danger
        ? AppColors.error
        : filled
            ? AppColors.brandNavy
            : AppColors.brandNavy;
    if (filled) {
      return FilledButton.icon(
        key: key,
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        label: Text(label),
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.brandNavy,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          elevation: 0,
        ),
      );
    }
    return OutlinedButton.icon(
      key: key,
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(
          color: danger ? AppColors.error.withValues(alpha: 0.35) : const Color(0xFFCBD5E1),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Widget _deviceRow(SiteDevice d, int index) {
    final syncFresh = _isFresh(d.lastSyncAt);
    final title = _deviceTitle(d, index);
    final idHint = d.name.trim().isNotEmpty && d.name != title
        ? _shortId(d.name)
        : (d.id.length > 8 ? _shortId(d.id) : '');

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onLongPress: () {
          final text = d.name.trim().isNotEmpty ? d.name : d.id;
          Clipboard.setData(ClipboardData(text: text));
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr(context, 'Copied'))),
          );
        },
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: syncFresh
                      ? AppColors.success.withValues(alpha: 0.12)
                      : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(
                  Icons.point_of_sale_rounded,
                  size: 20,
                  color: syncFresh ? AppColors.success : AppColors.textMutedLight,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              color: AppColors.brandNavy,
                            ),
                          ),
                        ),
                        if (d.appVersion.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEFF6FF),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'v${d.appVersion}',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: AppColors.primaryDark,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (idHint.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        idHint,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.textMutedLight,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 10,
                      runSpacing: 4,
                      children: [
                        _meta(
                          Icons.sync_rounded,
                          '${tr(context, 'Last sync')}: ${siteWhen(context, d.lastSyncAt)}',
                          syncFresh ? AppColors.success : AppColors.textSecondaryLight,
                        ),
                        _meta(
                          Icons.cloud_done_outlined,
                          '${tr(context, 'Last backup')}: ${siteWhen(context, d.lastBackupAt)}',
                          AppColors.textSecondaryLight,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _meta(IconData icon, String text, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }
}
