import 'package:flutter/material.dart';

import '../../core/db/settings_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/vouchers/voucher_client.dart';

/// The shared voucher server, and the key that says which branch this till is.
///
/// Every till in the branch pastes the same key. The server address is the same
/// for every branch; only the key changes.
class VoucherSettingsScreen extends StatefulWidget {
  const VoucherSettingsScreen({
    super.key,
    required this.settings,
    required this.onChanged,
  });

  final SettingsStore settings;
  final VoidCallback onChanged;

  @override
  State<VoucherSettingsScreen> createState() => _VoucherSettingsScreenState();
}

class _VoucherSettingsScreenState extends State<VoucherSettingsScreen> {
  late final TextEditingController _url = TextEditingController(
    text: widget.settings.voucherServerUrl,
  );
  late final TextEditingController _key = TextEditingController(
    text: widget.settings.voucherBranchKey ?? '',
  );
  bool _busy = false;

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final url = _url.text.trim();
    final key = _key.text.trim();
    widget.settings.voucherServerUrl = url;
    widget.settings.voucherBranchKey = key;
    widget.onChanged();
    if (key.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr(context, 'Saved'))),
      );
      return;
    }
    setState(() => _busy = true);
    final client = VoucherClient(baseUrl: url, branchKey: key);
    final reply = await client.hello();
    client.close();
    if (!mounted) return;
    setState(() => _busy = false);
    final message = reply.ok
        ? tr(context, 'Linked to POS')
        : (reply.error == 'not_configured'
            ? tr(context, 'Not linked to POS')
            : tr(context, 'Saved'));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Vouchers'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(tr(
            context,
            'Paste the branch key once. Every till in this branch uses the same key.',
          )),
          const SizedBox(height: 16),
          TextField(
            key: const Key('voucher-server-url'),
            controller: _url,
            decoration: InputDecoration(
              labelText: tr(context, 'Voucher server'),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('voucher-branch-key'),
            controller: _key,
            decoration: InputDecoration(
              labelText: tr(context, 'Branch voucher key'),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('voucher-settings-save'),
            onPressed: _busy ? null : _save,
            child: Text(tr(context, 'Save')),
          ),
        ],
      ),
    );
  }
}
