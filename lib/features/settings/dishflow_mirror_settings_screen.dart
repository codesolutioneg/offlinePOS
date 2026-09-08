import 'package:flutter/material.dart';

import '../../core/db/settings_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/sync/dishflow_firestore_sender.dart';

/// Point this till at a Dishflow Firebase branch so paid sales show for the owner.
///
/// The till still owns the sale in SQLite. This screen only configures the mirror
/// that runs when the line is up; selling never waits on it.
class DishflowMirrorSettingsScreen extends StatefulWidget {
  const DishflowMirrorSettingsScreen({
    super.key,
    required this.settings,
    required this.onChanged,
    this.sender,
  });

  final SettingsStore settings;
  final VoidCallback onChanged;
  final DishflowFirestoreSender? sender;

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Dishflow owner mirror')),
        actions: [
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
          SwitchListTile(
            key: const Key('dishflow-enabled'),
            title: Text(tr(context, 'Mirror paid sales to Dishflow')),
            subtitle: Text(tr(context,
                'When online, paid orders appear in owner Flash and reports. Selling never waits on the network.')),
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('dishflow-project'),
            controller: _projectId,
            decoration: InputDecoration(
              labelText: tr(context, 'Firebase project id'),
              hintText: 'odc-chat',
            ),
          ),
          TextField(
            key: const Key('dishflow-apikey'),
            controller: _apiKey,
            decoration: InputDecoration(
              labelText: tr(context, 'Firebase web API key'),
            ),
            obscureText: true,
          ),
          TextField(
            key: const Key('dishflow-connection'),
            controller: _connectionId,
            decoration: InputDecoration(
              labelText: tr(context, 'Odoo connection id'),
              helperText: tr(context,
                  'Must match the branch connection id Dishflow reports filter on.'),
            ),
          ),
          TextField(
            key: const Key('dishflow-branch-id'),
            controller: _branchId,
            decoration: InputDecoration(
              labelText: tr(context, 'Branch id (optional)'),
            ),
          ),
          TextField(
            key: const Key('dishflow-branch-name'),
            controller: _branchName,
            decoration: InputDecoration(
              labelText: tr(context, 'Branch name (optional)'),
            ),
          ),
          const SizedBox(height: 16),
          if (widget.sender != null)
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
        ],
      ),
    );
  }
}
