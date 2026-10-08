import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/cloud/backup_envelope.dart';
import '../../core/cloud/cloud_backup_service.dart';
import '../../core/cloud/cloud_client.dart';
import '../../core/cloud/pending_restore.dart';
import '../../core/cloud/recovery_key.dart';
import '../../core/i18n/l10n.dart';

/// Pair the till with the shop's backup server, see how the backups are going,
/// and bring a backup back.
///
/// A restore never touches the running database: the chosen backup is staged
/// beside it and swapped in on the next launch (see [PendingRestore]).
class CloudBackupScreen extends StatefulWidget {
  const CloudBackupScreen({super.key, required this.service, this.restore});

  final CloudBackupService service;
  final PendingRestore? restore;

  /// What a fresh till's server field starts with; set per build.
  static const String defaultUrl = String.fromEnvironment(
    'CLOUD_BACKUP_URL',
    defaultValue: 'https://posbackup.91.99.195.177.sslip.io',
  );

  @override
  State<CloudBackupScreen> createState() => _CloudBackupScreenState();
}

class _CloudBackupScreenState extends State<CloudBackupScreen> {
  final _url = TextEditingController();
  final _pairCode = TextEditingController();
  final _recoveryKey = TextEditingController();

  CloudBackupStatus? _status;
  bool _askForKey = false;
  bool _busy = false;
  String? _message;

  CloudBackupService get _service => widget.service;

  @override
  void initState() {
    super.initState();
    _service.changes.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    _service.changes.removeListener(_reload);
    _url.dispose();
    _pairCode.dispose();
    _recoveryKey.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final status = await _service.status();
    if (!mounted) return;
    setState(() {
      _status = status;
      if (_url.text.isEmpty) _url.text = status.url ?? CloudBackupScreen.defaultUrl;
    });
  }

  void _say(String message) => setState(() => _message = message);

  Future<void> _pair() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final shop = await _service.pair(
        url: _url.text,
        pairCode: _pairCode.text,
        recoveryKey: _askForKey ? _recoveryKey.text : null,
      );
      _pairCode.clear();
      _recoveryKey.clear();
      _askForKey = false;
      if (!mounted) return;
      _say(tr(context, 'Paired with {shop}.').replaceAll('{shop}', shop));
      await _service.runNow(reason: 'paired');
    } on RecoveryKeyNeeded {
      if (!mounted) return;
      setState(() => _askForKey = true);
      _say(tr(context,
          'This shop already has backups. Enter its recovery key from the first till.'));
    } on RecoveryKeyMismatch {
      if (!mounted) return;
      _say(tr(context, 'That is not this shop\'s recovery key.'));
    } on FormatException {
      if (!mounted) return;
      _say(tr(context, 'That recovery key is not complete. Check it and try again.'));
    } on CloudError catch (e) {
      _say(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _uploadNow() async {
    setState(() => _message = null);
    final outcome = await _service.runNow();
    final lastError = (await _service.status()).lastError;
    if (!mounted) return;
    _say(switch (outcome) {
      CloudBackupOutcome.uploaded => tr(context, 'Backup uploaded.'),
      CloudBackupOutcome.unchanged =>
        tr(context, 'Nothing changed since the last backup.'),
      CloudBackupOutcome.busy => tr(context, 'A backup is already running.'),
      CloudBackupOutcome.stressOrders => tr(context,
          'Stress Lab orders are on this till. Remove them before backing up.'),
      CloudBackupOutcome.notConfigured => tr(context, 'Pair this till first.'),
      CloudBackupOutcome.failed => lastError ?? tr(context, 'Backup failed.'),
    });
  }

  Future<void> _showRecoveryKey() async {
    final key = await _service.recoveryKey();
    if (!mounted) return;
    final text = key.format();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'Recovery key')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr(context,
                'Every backup is locked with this key. The server cannot open them without it. Write it down and keep it away from the till: lose it and the backups are lost too.')),
            const SizedBox(height: 16),
            SelectableText(
              text,
              key: const Key('cloud-recovery-key'),
              style: const TextStyle(
                  fontFamily: 'monospace', fontSize: 18, letterSpacing: 1),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: text)),
            child: Text(tr(context, 'Copy')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr(context, 'OK')),
          ),
        ],
      ),
    );
  }

  Future<void> _unpair() async {
    final ok = await _confirm(
      tr(context, 'Unpair this till?'),
      tr(context,
          'Backups stop until it is paired again. Backups already on the server stay there.'),
    );
    if (ok) await _service.unpair();
  }

  Future<void> _restore() async {
    final staging = widget.restore;
    final connection = await _service.connection();
    if (staging == null || connection == null) return;
    final (:client, :token) = connection;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final backups = await client.list(token);
      if (!mounted) return;
      if (backups.isEmpty) {
        _say(tr(context, 'The server has no backups for this shop yet.'));
        return;
      }
      final picked = await _pickBackup(backups);
      if (picked == null || !mounted) return;

      final held = await _service.heldRecoveryKey();
      final key = held != null && held.id == picked.keyId
          ? held
          : await _askRecoveryKey();
      if (key == null || !mounted) return;

      final sealed = await client.download(token, picked.id);
      final OpenedBackup opened;
      try {
        opened = await BackupEnvelope.open(sealed, key);
      } on WrongRecoveryKey {
        if (mounted) _say(tr(context, 'That recovery key does not open this backup.'));
        return;
      }
      if (!mounted) return;
      final h = opened.header;
      final ok = await _confirm(
        tr(context, 'Replace this till\'s data?'),
        tr(context,
                'Everything on this till will be replaced by the backup from {device} taken {when}. The current data is kept in a file beside it. This till takes over that device\'s identity: do not run both at once.')
            .replaceAll('{device}', h.deviceName.isEmpty ? h.deviceId : h.deviceName)
            .replaceAll('{when}', _when(h.createdAt)),
      );
      if (!ok) return;
      await staging.stage(opened.database, databaseKey: h.dbKey);
      if (key.id != held?.id) await _service.adoptRecoveryKey(key);
      if (!mounted) return;
      _say(tr(context, 'Restore is ready. Close the app and open it again to finish.'));
    } on CloudError catch (e) {
      _say(e.message);
    } finally {
      client.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancelRestore() async {
    await widget.restore?.cancel();
    if (!mounted) return;
    _say(tr(context, 'The staged restore was cancelled.'));
  }

  Future<CloudBackupInfo?> _pickBackup(List<CloudBackupInfo> backups) =>
      showDialog<CloudBackupInfo>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(tr(context, 'Choose a backup')),
          children: [
            for (final b in backups)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, b),
                child: ListTile(
                  title: Text(b.deviceName.isEmpty ? b.deviceId : b.deviceName),
                  subtitle: Text(
                      '${_when(b.createdAt)} · ${_size(b.size)} · ${b.reason}'),
                ),
              ),
          ],
        ),
      );

  Future<RecoveryKey?> _askRecoveryKey() async {
    final field = TextEditingController();
    try {
      final text = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(tr(context, 'Recovery key')),
          content: TextField(
            controller: field,
            autofocus: true,
            decoration: InputDecoration(
              labelText: tr(context, 'Enter the shop\'s recovery key'),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr(context, 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, field.text),
              child: Text(tr(context, 'OK')),
            ),
          ],
        ),
      );
      if (text == null) return null;
      return RecoveryKey.parse(text);
    } on FormatException {
      if (mounted) {
        _say(tr(context, 'That recovery key is not complete. Check it and try again.'));
      }
      return null;
    } finally {
      field.dispose();
    }
  }

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr(context, 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr(context, 'Continue')),
            ),
          ],
        ),
      ) ??
      false;

  static String _when(DateTime at) {
    final l = at.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  static String _size(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(0)} KB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Cloud backup'))),
      body: status == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  tr(context,
                      'A copy of everything on this till is encrypted here and sent to the shop server every hour and at every shift close, whenever there is internet. Selling never waits on it.'),
                  style: muted,
                ),
                const SizedBox(height: 16),
                if (widget.restore?.isStaged ?? false)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.restore),
                      title: Text(tr(context,
                          'A restore is waiting. It is applied the next time the app opens.')),
                      trailing: TextButton(
                        key: const Key('cloud-cancel-restore'),
                        onPressed: _cancelRestore,
                        child: Text(tr(context, 'Cancel')),
                      ),
                    ),
                  ),
                if (status.configured) ..._paired(status, muted) else ..._unpaired(),
                if (_message != null) ...[
                  const SizedBox(height: 16),
                  Text(_message!, key: const Key('cloud-message')),
                ],
              ],
            ),
    );
  }

  List<Widget> _paired(CloudBackupStatus status, TextStyle muted) => [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            status.lastError == null ? Icons.cloud_done : Icons.cloud_off,
            color: status.lastError == null ? Colors.green : Colors.orange,
          ),
          title: Text(status.shopName ?? ''),
          subtitle: Text(status.url ?? ''),
        ),
        Text(
          status.lastSuccessAt == null
              ? tr(context, 'No backup yet')
              : tr(context, 'Last backup: {t}')
                  .replaceAll('{t}', _when(status.lastSuccessAt!)),
          key: const Key('cloud-last-backup'),
        ),
        if (status.lastError != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              tr(context, 'Last attempt failed: {e}')
                  .replaceAll('{e}', status.lastError!),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              key: const Key('cloud-upload-now'),
              onPressed: status.running || _busy ? null : _uploadNow,
              icon: const Icon(Icons.cloud_upload),
              label: Text(status.running
                  ? tr(context, 'Uploading…')
                  : tr(context, 'Back up now')),
            ),
            OutlinedButton.icon(
              key: const Key('cloud-show-key'),
              onPressed: _showRecoveryKey,
              icon: const Icon(Icons.key),
              label: Text(tr(context, 'Show recovery key')),
            ),
            if (widget.restore != null)
              OutlinedButton.icon(
                key: const Key('cloud-restore'),
                onPressed: _busy ? null : _restore,
                icon: const Icon(Icons.restore),
                label: Text(tr(context, 'Restore from cloud')),
              ),
            TextButton(
              key: const Key('cloud-unpair'),
              onPressed: _busy ? null : _unpair,
              child: Text(tr(context, 'Unpair')),
            ),
          ],
        ),
      ];

  List<Widget> _unpaired() => [
        TextField(
          key: const Key('cloud-url'),
          controller: _url,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            labelText: tr(context, 'Server address'),
            hintText: 'https://backup.example.com',
          ),
        ),
        TextField(
          key: const Key('cloud-pair-code'),
          controller: _pairCode,
          decoration: InputDecoration(
            labelText: tr(context, 'Pairing code'),
            helperText: tr(context, 'From the server, one per shop.'),
          ),
        ),
        if (_askForKey)
          TextField(
            key: const Key('cloud-pair-recovery-key'),
            controller: _recoveryKey,
            decoration: InputDecoration(
              labelText: tr(context, 'Enter the shop\'s recovery key'),
            ),
          ),
        const SizedBox(height: 16),
        FilledButton(
          key: const Key('cloud-pair'),
          onPressed: _busy ? null : _pair,
          child: Text(_busy ? tr(context, 'Pairing…') : tr(context, 'Pair')),
        ),
      ];
}
