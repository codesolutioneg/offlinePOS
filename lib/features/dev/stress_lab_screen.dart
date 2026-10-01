import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import 'stress_lab_controls.dart';
import 'stress_lab_runner.dart';
import 'stress_lab_store.dart';
import 'stress_note.dart';
import 'stress_report_card.dart';
import 'stress_report_log.dart';

/// Load and scenario runs on this till's own database, for a test bench only.
///
/// Everything it creates carries [kStressNote] and stays on the device until the
/// shift is closed, so "Clean up" must run before any shift close on a till
/// that talks to a real Odoo.
class StressLabScreen extends StatefulWidget {
  const StressLabScreen(
      {super.key, required this.runner, required this.onChanged, this.log});

  final StressLabRunner runner;

  /// Keeps every run on disk. Null in tests.
  final StressReportLog? log;

  /// Tells the floor to redraw, so filled tables show as busy straight away.
  final VoidCallback onChanged;

  @override
  State<StressLabScreen> createState() => _StressLabScreenState();
}

class _StressLabScreenState extends State<StressLabScreen> {
  final _count = TextEditingController(text: '100');
  final _seconds = TextEditingController(text: '60');
  final _history = TextEditingController(text: '5000');
  final List<StressReport> _reports = [];
  String? _running;
  double _progress = 0;

  @override
  void dispose() {
    _count.dispose();
    _seconds.dispose();
    _history.dispose();
    super.dispose();
  }

  int _read(TextEditingController c, int fallback) => int.tryParse(c.text.trim()) ?? fallback;

  void _tick(int done, int total) {
    if (mounted) setState(() => _progress = total == 0 ? 1 : done / total);
  }

  Future<void> _run(String label, Future<StressReport> Function() job) async {
    if (_running != null) return;
    setState(() {
      _running = label;
      _progress = 0;
    });
    try {
      final report = await job();
      if (mounted) setState(() => _reports.insert(0, report));
      await widget.log
          ?.append(report)
          .catchError((Object e) => debugPrint('[STRESS] report not saved: $e'));
    } catch (e) {
      if (mounted) {
        setState(() => _reports.insert(
            0, StressReport(label, failed: 1, notes: [StressNote('{error}', {'error': '$e'}, true)])));
      }
    } finally {
      widget.onChanged();
      if (mounted) setState(() => _running = null);
    }
  }

  void _flood() => _run('Order flood', () => widget.runner.flood(
      _read(_count, 100), Duration(seconds: _read(_seconds, 60)), _tick));

  void _fill() => _run('Fill every table', () => widget.runner.fillTables(_tick));

  void _settle() => _run('Settle the tables', () => widget.runner.settleTables(_tick));

  void _grow() => _run('Pay on a full till',
      () => widget.runner.growAndTime(_read(_history, 5000), _tick));

  void _cleanup() => _run('Clean up', () async {
    final done = await widget.runner.store.cleanup();
    return StressReport(
      'Clean up',
      done: done.removed,
      notes: cleanupNotes(done),
    );
  });

  @override
  Widget build(BuildContext context) {
    final busy = _running != null;
    final printer = widget.runner.printer;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Stress Lab'))),
      body: Column(
        children: [
          const StressLabWarning(),
          StressLabControls(
            count: _count,
            seconds: _seconds,
            history: _history,
            enabled: !busy,
            printing: printer.available ? printer.enabled : null,
            onPrintingChanged: (on) => setState(() => printer.enabled = on),
            onFlood: _flood,
            onFill: _fill,
            onSettle: _settle,
            onGrow: _grow,
            onCleanup: _cleanup,
          ),
          if (busy) ...[
            Text('${tr(context, _running ?? '')}…'),
            LinearProgressIndicator(value: _progress),
          ],
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _reports.length,
              itemBuilder: (_, i) => StressReportCard(report: _reports[i]),
            ),
          ),
        ],
      ),
    );
  }
}
