import 'package:flutter/material.dart';

import '../../core/db/settings_store.dart';
import '../../core/email/email_service.dart';
import '../../core/email/smtp_config.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';

/// Where the Z report goes at the end of the night.
///
/// One screen for the shop's own mailbox and the people who want the figures.
/// The password is stored on this device like every other setting, in a database
/// that is encrypted at rest, and it is never shown back in the clear once saved.
class EmailSettingsScreen extends StatefulWidget {
  const EmailSettingsScreen({
    super.key,
    required this.settings,
    required this.onChanged,
    this.emailer,
  });

  final SettingsStore settings;
  final VoidCallback onChanged;

  /// Null on a build with no sender wired, which hides the test button rather
  /// than showing one that cannot answer.
  final EmailService? emailer;

  @override
  State<EmailSettingsScreen> createState() => _EmailSettingsScreenState();
}

class _EmailSettingsScreenState extends State<EmailSettingsScreen> {
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _from;
  late final TextEditingController _recipients;
  late SmtpSecurity _security;
  late bool _enabled;

  String? _testResult;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    final s = widget.settings;
    _host = TextEditingController(text: s.smtpHost ?? '');
    _port = TextEditingController(text: '${s.smtpPort}');
    _username = TextEditingController(text: s.smtpUsername ?? '');
    _password = TextEditingController(text: s.smtpPassword ?? '');
    _from = TextEditingController(text: s.smtpFrom ?? '');
    _recipients = TextEditingController(text: s.zReportRecipients.join(', '));
    _security = s.smtpSecurity;
    _enabled = s.emailZReport;
  }

  @override
  void dispose() {
    for (final c in [_host, _port, _username, _password, _from, _recipients]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final s = widget.settings;
    s.smtpHost = _host.text;
    s.smtpSecurity = _security;
    s.smtpPort = int.tryParse(_port.text.trim()) ??
        SmtpConfig.defaultPortFor(_security);
    s.smtpUsername = _username.text;
    s.smtpPassword = _password.text;
    s.smtpFrom = _from.text;
    s.zReportRecipients = _recipients.text.split(RegExp('[,;]'));
    s.emailZReport = _enabled;
    widget.onChanged();
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      key: const Key('email-saved'),
      content: Text(tr(context, 'Saved')),
    ));
  }

  Future<void> _test() async {
    final emailer = widget.emailer;
    if (emailer == null) return;
    // Saved first, or the test would be of whatever was configured last time
    // rather than what is on screen.
    _save();
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final failure = await emailer.trySend(
      subject: 'offlinePOS test',
      body: 'This is a test message from the till. Nothing else is in it.',
    );
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = failure ?? '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final emailer = widget.emailer;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Email the Z report'))),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            color: AppColors.info.withValues(alpha: 0.08),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                tr(context,
                    'Sent when a shift is closed. If it cannot be sent the till keeps trying in the background, and a cash-up is never held up by it.'),
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ),
          SwitchListTile(
            key: const Key('email-enabled'),
            value: _enabled,
            title: Text(tr(context, 'Email the Z report at shift close')),
            onChanged: (v) => setState(() => _enabled = v),
          ),
          const Divider(),
          _field(_recipients, 'Send to',
              key: 'email-recipients',
              hint: 'owner@shop.com, accounts@shop.com'),
          _field(_from, 'From address', key: 'email-from'),
          const Divider(),
          _field(_host, 'Mail server', key: 'email-host', hint: 'smtp.gmail.com'),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: DropdownButtonFormField<SmtpSecurity>(
              key: const Key('email-security'),
              initialValue: _security,
              decoration: InputDecoration(labelText: tr(context, 'Security')),
              items: [
                DropdownMenuItem(
                    value: SmtpSecurity.ssl, child: Text(tr(context, 'SSL / TLS'))),
                DropdownMenuItem(
                    value: SmtpSecurity.startTls, child: Text(tr(context, 'STARTTLS'))),
                DropdownMenuItem(
                    value: SmtpSecurity.none, child: Text(tr(context, 'None'))),
              ],
              onChanged: (v) => setState(() {
                if (v == null) return;
                _security = v;
                // The port almost always follows the security choice, and nobody
                // knows theirs, so it is moved with it.
                _port.text = '${SmtpConfig.defaultPortFor(v)}';
              }),
            ),
          ),
          _field(_port, 'Port', key: 'email-port', number: true),
          _field(_username, 'Username', key: 'email-username'),
          _field(_password, 'Password', key: 'email-password', obscure: true),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(
              key: const Key('email-save'),
              onPressed: _save,
              icon: const Icon(Icons.save),
              label: Text(tr(context, 'Save')),
            ),
            if (emailer != null)
              OutlinedButton.icon(
                key: const Key('email-test'),
                onPressed: _testing ? null : _test,
                icon: _testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.send),
                label: Text(tr(context, _testing ? 'Sending...' : 'Send test')),
              ),
          ]),
          if (_testResult != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _testResult!.isEmpty
                    ? tr(context, 'Sent. Check the inbox.')
                    : '${tr(context, 'Not sent')}: ${_testResult!}',
                key: const Key('email-test-result'),
                style: TextStyle(
                    color: _testResult!.isEmpty
                        ? AppColors.success
                        : AppColors.error),
              ),
            ),
          if (emailer != null && emailer.pending > 0)
            ListTile(
              key: const Key('email-pending'),
              leading: const Icon(Icons.schedule),
              title: Text(
                  '${emailer.pending} ${tr(context, 'report(s) still waiting to be sent')}'),
              subtitle: emailer.lastError == null ? null : Text(emailer.lastError!),
            ),
          if (emailer != null && emailer.abandoned > 0)
            ListTile(
              key: const Key('email-abandoned'),
              leading: const Icon(Icons.error_outline, color: AppColors.error),
              title: Text(
                  '${emailer.abandoned} ${tr(context, 'report(s) were never sent')}'),
              subtitle: Text(tr(context, 'Fix the settings above, then send a test.')),
            ),
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    required String key,
    String? hint,
    bool obscure = false,
    bool number = false,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: TextField(
          key: Key(key),
          controller: controller,
          obscureText: obscure,
          keyboardType: number ? TextInputType.number : TextInputType.text,
          decoration: InputDecoration(
            labelText: tr(context, label),
            hintText: hint,
          ),
        ),
      );
}
