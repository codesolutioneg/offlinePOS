import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/i18n/l10n.dart';
import '../../../core/theme/app_colors.dart';
import '../stress_lab_store.dart';
import '../stress_note.dart';
import 'stress_day_log.dart';
import 'stress_day_order_tile.dart';
import 'stress_day_runner.dart';

/// Runs one full-day (or delivery-only) stress from the floor and shows what
/// happened to every order, with the ones that went wrong a filter away.
class StressDayScreen extends StatefulWidget {
  const StressDayScreen({
    super.key,
    required this.runner,
    required this.config,
    required this.store,
    required this.onChanged,
    this.log,
  });

  final StressDayRunner runner;
  final StressDayConfig config;

  /// For Clean up, which takes every lab order back out of the till.
  final StressLabStore store;

  /// Tells the floor to redraw once tables have been used and released.
  final VoidCallback onChanged;

  /// Keeps the run on disk. Null in tests.
  final StressDayLog? log;

  @override
  State<StressDayScreen> createState() => _StressDayScreenState();
}

class _StressDayScreenState extends State<StressDayScreen> {
  StressDayReport? _report;
  List<StressNote> _cleanup = const [];
  bool _busy = true;
  bool _problemsOnly = false;
  double _progress = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_run()));
  }

  Future<void> _run() async {
    try {
      final report = await widget.runner.run(
        widget.config,
        onProgress: (done, total) {
          if (mounted) {
            setState(() => _progress = total == 0 ? 1 : done / total);
          }
        },
      );
      if (mounted) setState(() => _report = report);
      await widget.log
          ?.write(report)
          .catchError(
            (Object e) => debugPrint('[STRESS] day report not saved: $e'),
          );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      widget.onChanged();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clean() async {
    setState(() => _busy = true);
    try {
      final done = await widget.store.cleanup();
      if (mounted) setState(() => _cleanup = cleanupNotes(done));
    } finally {
      widget.onChanged();
      if (mounted) setState(() => _busy = false);
    }
  }

  String _say(StressNote n) => n.fill(tr(context, n.template));

  @override
  Widget build(BuildContext context) {
    final report = _report;
    final title = widget.config.mode == StressDayMode.fullDay
        ? 'Full-day stress'
        : 'Delivery stress';
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, title)),
        actions: [
          TextButton.icon(
            key: const Key('stress-day-cleanup'),
            onPressed: _busy ? null : _clean,
            icon: const Icon(Icons.cleaning_services_outlined),
            label: Text(tr(context, 'Clean up')),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_busy)
            LinearProgressIndicator(value: report == null ? _progress : null),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _error!,
                style: const TextStyle(color: AppColors.error),
              ),
            ),
          for (final n in _cleanup) _noteRow(n),
          if (report != null) _summary(report),
          if (report != null) Expanded(child: _orders(report)),
        ],
      ),
    );
  }

  Widget _noteRow(StressNote n) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
    child: Align(
      alignment: AlignmentDirectional.centerStart,
      child: Text(
        '• ${_say(n)}',
        style: TextStyle(color: n.alarm ? AppColors.error : null),
      ),
    ),
  );

  Widget _summary(StressDayReport r) {
    final lat = r.latency;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          for (final n in r.notes) _noteRow(n),
          if (lat.count > 0)
            _noteRow(
              StressNote(
                'Time per operation: avg {avg} ms · p95 {p95} ms · max {max} ms',
                {
                  'avg': lat.avgMs.toStringAsFixed(1),
                  'p95': lat.percentileMs(0.95).toStringAsFixed(1),
                  'max': lat.maxMs.toStringAsFixed(1),
                },
              ),
            ),
          if (widget.log?.lastPath != null)
            _noteRow(StressNote('{path}', {'path': widget.log!.lastPath!})),
          SwitchListTile(
            key: const Key('stress-day-problems-only'),
            title: Text(tr(context, 'Problems only')),
            value: _problemsOnly,
            onChanged: (v) => setState(() => _problemsOnly = v),
          ),
        ],
      ),
    );
  }

  Widget _orders(StressDayReport r) {
    final shown = _problemsOnly
        ? r.traces.where((t) => t.hasProblems).toList()
        : r.traces;
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: shown.length,
      itemBuilder: (_, i) => StressDayOrderTile(trace: shown[i]),
    );
  }
}
