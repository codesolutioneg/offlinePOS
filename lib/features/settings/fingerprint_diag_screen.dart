import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/auth/fingerprint_diagnostics.dart';
import '../../core/i18n/l10n.dart';

/// Shows auto-setup results and log paths so support can track a bad till.
class FingerprintDiagScreen extends StatefulWidget {
  const FingerprintDiagScreen({super.key});

  @override
  State<FingerprintDiagScreen> createState() => _FingerprintDiagScreenState();
}

class _FingerprintDiagScreenState extends State<FingerprintDiagScreen> {
  FingerprintDiagReport? _report;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    final report = await FingerprintDiagnostics().probe();
    if (!mounted) return;
    setState(() {
      _report = report;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = _report;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Fingerprint setup')),
        actions: [
          IconButton(
            key: const Key('fp-diag-refresh'),
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _busy && r == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ListTile(
                  leading: Icon(
                    r?.ok == true ? Icons.check_circle : Icons.error_outline,
                    color: r?.ok == true ? Colors.green : Colors.red,
                  ),
                  title: Text(r?.summary ?? tr(context, 'Checking…')),
                  subtitle: Text(
                    r?.ok == true
                        ? tr(context, 'Reader ready')
                        : tr(context, 'Fix the failed checks below'),
                  ),
                ),
                if (r != null && r.issues.isNotEmpty) ...[
                  const Divider(),
                  Text(tr(context, 'Issues'),
                      style: Theme.of(context).textTheme.titleMedium),
                  for (final i in r.issues)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.warning_amber, size: 20),
                      title: Text(i),
                    ),
                ],
                if (r != null && r.checks.isNotEmpty) ...[
                  const Divider(),
                  Text(tr(context, 'Checks'),
                      style: Theme.of(context).textTheme.titleMedium),
                  for (final c in r.checks)
                    ListTile(
                      dense: true,
                      leading: Icon(
                        c.ok ? Icons.check : Icons.close,
                        color: c.ok ? Colors.green : Colors.red,
                        size: 20,
                      ),
                      title: Text(c.code),
                      subtitle: Text(c.detail),
                    ),
                ],
                if (r != null) ...[
                  const Divider(),
                  ListTile(
                    title: Text(tr(context, 'Log file')),
                    subtitle: Text(r.logPath ?? '—'),
                    trailing: IconButton(
                      icon: const Icon(Icons.copy),
                      onPressed: r.logPath == null
                          ? null
                          : () async {
                              await Clipboard.setData(
                                  ClipboardData(text: r.logPath!));
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                      content: Text(tr(context, 'Copied'))),
                                );
                              }
                            },
                    ),
                  ),
                  ListTile(
                    title: Text(tr(context, 'Status file')),
                    subtitle: Text(r.statusFile ?? '—'),
                    trailing: IconButton(
                      icon: const Icon(Icons.copy),
                      onPressed: r.statusFile == null
                          ? null
                          : () async {
                              await Clipboard.setData(
                                  ClipboardData(text: r.statusFile!));
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                      content: Text(tr(context, 'Copied'))),
                                );
                              }
                            },
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                FilledButton.icon(
                  key: const Key('fp-diag-rerun'),
                  onPressed: _busy ? null : _refresh,
                  icon: const Icon(Icons.build_circle_outlined),
                  label: Text(tr(context, 'Re-check / install')),
                ),
              ],
            ),
    );
  }
}
