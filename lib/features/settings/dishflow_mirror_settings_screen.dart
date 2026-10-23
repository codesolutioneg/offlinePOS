import 'package:flutter/material.dart';

import '../../core/db/settings_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/sync/dishflow_firestore_sender.dart';
import '../../core/sync/dishflow_mirror.dart';
import '../../domain/table_section_config.dart';

/// Point this till at a Dishflow Firebase branch so paid sales show for the owner.
///
/// The till still owns the sale in SQLite. This screen only configures the mirror
/// that runs when the line is up; selling never waits on it.
///
/// On a secondary till the fields are read-only: the primary owns the connection.
class DishflowMirrorSettingsScreen extends StatefulWidget {
  const DishflowMirrorSettingsScreen({
    super.key,
    required this.settings,
    required this.onChanged,
    this.sender,
    this.planResend,
    this.resend,
  });

  final SettingsStore settings;
  final VoidCallback onChanged;
  final DishflowFirestoreSender? sender;

  /// The open shift's sales as the mirror sees them. With [resend], shows the
  /// catch-up button for sales paid before the mirror was configured.
  final DishflowResendPlan Function()? planResend;
  final Future<int> Function(DishflowResendPlan plan)? resend;

  @override
  State<DishflowMirrorSettingsScreen> createState() =>
      _DishflowMirrorSettingsScreenState();
}

class _DishflowMirrorSettingsScreenState
    extends State<DishflowMirrorSettingsScreen> {
  late final TextEditingController _projectId;
  late final TextEditingController _apiKey;
  late final TextEditingController _connectionId;
  late final TextEditingController _branchId;
  late final TextEditingController _branchName;
  late bool _enabled;
  String? _testResult;
  bool _testing = false;
  String? _resendResult;
  bool _resending = false;

  bool get _readOnly => widget.settings.deviceRole == DeviceRole.secondary;

  @override
  void initState() {
    super.initState();
    final s = widget.settings;
    _enabled = s.dishflowMirrorEnabled;
    _projectId = TextEditingController(text: s.dishflowProjectId ?? '');
    _apiKey = TextEditingController(text: s.dishflowApiKey ?? '');
    _connectionId =
        TextEditingController(text: s.dishflowOdooConnectionId ?? '');
    _branchId = TextEditingController(text: s.dishflowBranchId ?? '');
    _branchName = TextEditingController(text: s.dishflowBranchName ?? '');
  }

  @override
  void dispose() {
    _projectId.dispose();
    _apiKey.dispose();
    _connectionId.dispose();
    _branchId.dispose();
    _branchName.dispose();
    super.dispose();
  }

  void _save() {
    if (_readOnly) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr(context,
              'Dishflow mirror is owned by the primary till. Join as primary to edit.'))));
      return;
    }
    final s = widget.settings;
    s.dishflowMirrorEnabled = _enabled;
    s.dishflowProjectId = _projectId.text;
    s.dishflowApiKey = _apiKey.text;
    s.dishflowOdooConnectionId = _connectionId.text;
    s.dishflowBranchId = _branchId.text;
    s.dishflowBranchName = _branchName.text;
    widget.onChanged();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr(context, 'Saved'))),
      );
    }
  }

  Future<void> _test() async {
    final sender = widget.sender;
    if (sender == null) return;
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final result = await sender.testConnection(
      projectId: _projectId.text.trim(),
      apiKey: _apiKey.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = result == 'ok'
          ? tr(context, 'Connected. A ping was written to diagnostics.')
          : result;
    });
  }

  bool get _edited {
    final s = widget.settings;
    String v(String? x) => (x ?? '').trim();
    return _enabled != s.dishflowMirrorEnabled ||
        _projectId.text.trim() != v(s.dishflowProjectId) ||
        _apiKey.text.trim() != v(s.dishflowApiKey) ||
        _connectionId.text.trim() != v(s.dishflowOdooConnectionId) ||
        _branchId.text.trim() != v(s.dishflowBranchId) ||
        _branchName.text.trim() != v(s.dishflowBranchName);
  }

  void _say(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  Future<void> _resendOpenShift() async {
    final plan = widget.planResend;
    final resend = widget.resend;
    if (plan == null || resend == null) return;
    // Queued rows carry the settings they were queued under, so unsaved edits
    // would send the sales somewhere the till is not configured for.
    if (!_readOnly && _edited) {
      _say(tr(context, 'Save the settings first.'));
      return;
    }
    if (!widget.settings.dishflowMirrorReady) {
      _say(tr(context,
          'Turn the mirror on and fill the project id, API key and connection id first.'));
      return;
    }
    final p = plan();
    if (!p.shiftOpen) {
      setState(() => _resendResult = tr(context, 'No shift is open on this till.'));
      return;
    }
    if (p.toSend.isEmpty) {
      setState(() => _resendResult = tr(context,
              'All {total} sales of the open shift are already sent or waiting to send.')
          .replaceAll('{total}', '${p.total}'));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(ctx, 'Resend open shift sales')),
        content: Text(_planText(ctx, p)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(tr(ctx, 'Cancel')),
          ),
          FilledButton(
            key: const Key('dishflow-resend-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(tr(ctx, 'Send')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _resending = true);
    final queued = await resend(p);
    if (!mounted) return;
    setState(() {
      _resending = false;
      _resendResult = tr(context,
              '{n} sales queued for Dishflow. They go out with the normal sync when online.')
          .replaceAll('{n}', '$queued');
    });
  }

  String _planText(BuildContext context, DishflowResendPlan p) => [
        tr(context, 'Paid sales on this till in the open shift: {n}')
            .replaceAll('{n}', '${p.total - p.otherTills}'),
        tr(context, 'Already sent: {n}').replaceAll('{n}', '${p.sent}'),
        tr(context, 'Waiting to send: {n}').replaceAll('{n}', '${p.waiting}'),
        if (p.refused > 0)
          tr(context, 'Refused before, will retry: {n}')
              .replaceAll('{n}', '${p.refused}'),
        if (p.otherTills > 0)
          tr(context,
                  'From the other tills: {n} (one already in Dishflow is overwritten, not doubled)')
              .replaceAll('{n}', '${p.otherTills}'),
        tr(context, 'Will send now: {n}').replaceAll('{n}', '${p.toSend.length}'),
      ].join('\n');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Dishflow owner mirror')),
        actions: [
          if (!_readOnly)
            TextButton(
              key: const Key('dishflow-save'),
              onPressed: _save,
              child: Text(tr(context, 'Save')),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_readOnly)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                tr(context,
                    'Dishflow mirror is owned by the primary till. Join as primary to edit.'),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          SwitchListTile(
            key: const Key('dishflow-enabled'),
            title: Text(tr(context, 'Mirror paid sales to Dishflow')),
            subtitle: Text(tr(context,
                'When online, paid orders appear in owner Flash and reports. Selling never waits on the network.')),
            value: _enabled,
            onChanged: _readOnly ? null : (v) => setState(() => _enabled = v),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('dishflow-project'),
            controller: _projectId,
            readOnly: _readOnly,
            decoration: InputDecoration(
              labelText: tr(context, 'Firebase project id'),
              hintText: 'odc-chat',
            ),
          ),
          TextField(
            key: const Key('dishflow-apikey'),
            controller: _apiKey,
            readOnly: _readOnly,
            decoration: InputDecoration(
              labelText: tr(context, 'Firebase web API key'),
            ),
            obscureText: true,
          ),
          TextField(
            key: const Key('dishflow-connection'),
            controller: _connectionId,
            readOnly: _readOnly,
            decoration: InputDecoration(
              labelText: tr(context, 'Odoo connection id'),
              helperText: tr(context,
                  'Must match the branch connection id Dishflow reports filter on.'),
            ),
          ),
          TextField(
            key: const Key('dishflow-branch-id'),
            controller: _branchId,
            readOnly: _readOnly,
            decoration: InputDecoration(
              labelText: tr(context, 'Branch id (optional)'),
            ),
          ),
          TextField(
            key: const Key('dishflow-branch-name'),
            controller: _branchName,
            readOnly: _readOnly,
            decoration: InputDecoration(
              labelText: tr(context, 'Branch name (optional)'),
            ),
          ),
          const SizedBox(height: 16),
          if (widget.sender != null && !_readOnly)
            FilledButton.tonal(
              key: const Key('dishflow-test'),
              onPressed: _testing ? null : _test,
              child: Text(_testing
                  ? tr(context, 'Testing…')
                  : tr(context, 'Test connection')),
            ),
          if (_testResult != null) ...[
            const SizedBox(height: 12),
            Text(_testResult!, key: const Key('dishflow-test-result')),
          ],
          // The primary sends every till's sales; a secondary still has its own.
          if (widget.planResend != null && widget.resend != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const Key('dishflow-resend'),
              onPressed: _resending ? null : _resendOpenShift,
              icon: const Icon(Icons.replay),
              label: Text(tr(context, 'Resend open shift sales')),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                tr(
                    context,
                    widget.settings.isLanPrimary
                        ? 'For sales paid before the mirror was set up, on every till. Press it here on the primary.'
                        : 'For sales paid before the mirror was set up. Already sent ones are skipped.'),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
          if (_resendResult != null) ...[
            const SizedBox(height: 12),
            Text(_resendResult!, key: const Key('dishflow-resend-result')),
          ],
        ],
      ),
    );
  }
}
