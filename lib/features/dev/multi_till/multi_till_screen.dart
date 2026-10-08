import 'package:flutter/material.dart';

import '../../../core/i18n/l10n.dart';
import 'multi_till_runner.dart';

/// Runs a multi-till stress and shows it: progress while the tills sell, then
/// every session with its Odoo order and what reached the reports site.
class MultiTillScreen extends StatefulWidget {
  const MultiTillScreen({super.key, required this.runner, required this.config});

  final MultiTillRunner runner;
  final MultiTillConfig config;

  @override
  State<MultiTillScreen> createState() => _MultiTillScreenState();
}

class _MultiTillScreenState extends State<MultiTillScreen> {
  String _step = '';
  int _done = 0;
  int _total = 1;
  MultiTillReport? _report;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final report = await widget.runner.run(
        widget.config,
        onProgress: (step, done, total) {
          if (!mounted) return;
          setState(() {
            _step = step;
            _done = done;
            _total = total == 0 ? 1 : total;
          });
        },
      );
      if (mounted) setState(() => _report = report);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    final running = report == null && _error == null;
    return PopScope(
      canPop: !running,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr(context, 'Multi-till stress')),
          automaticallyImplyLeading: !running,
        ),
        body: _error != null
            ? Center(child: Text('$_error', key: const Key('multi-till-error')))
            : report == null
                ? _progress(context)
                : _result(context, report),
      ),
    );
  }

  Widget _progress(BuildContext context) => Center(
        child: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: _done / _total),
              const SizedBox(height: 16),
              Text(_step, key: const Key('multi-till-step')),
              const SizedBox(height: 4),
              Text(
                tr(context, '{a} points of sale, {b} cashiers each')
                    .replaceAll('{a}', '${widget.config.tills}')
                    .replaceAll('{b}', '${widget.config.cashiers}'),
              ),
            ],
          ),
        ),
      );

  Widget _result(BuildContext context, MultiTillReport r) {
    final theme = Theme.of(context);
    final took = r.finished!.difference(r.started);
    final ok = r.problems.isEmpty;
    final c = r.config;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          key: const Key('multi-till-verdict'),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: ok ? const Color(0xFFDCFCE7) : const Color(0xFFFEE2E2),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(children: [
            Icon(ok ? Icons.check_circle : Icons.error,
                color: ok ? const Color(0xFF15803D) : const Color(0xFFB91C1C)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                ok
                    ? tr(context, 'No problems found')
                    : tr(context, '{n} problems found').replaceAll('{n}', '${r.problems.length}'),
                style: theme.textTheme.titleMedium,
              ),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 12, runSpacing: 12, children: [
          _stat(context, 'Orders', '${r.rung.length}', 'multi-till-orders-total'),
          _stat(context, 'Total', r.total.toStringAsFixed(2), 'multi-till-total'),
          _stat(context, 'Sessions', '${r.sessions.length}', 'multi-till-sessions-total'),
          if (c.sendToOdoo)
            _stat(context, 'Booked in Odoo', '${r.odooBooked} / ${r.sessions.length}',
                'multi-till-odoo-total'),
          if (c.uploads)
            _stat(context, 'On the reports site', '${r.uploadedOrders.length} / ${r.rung.length}',
                'multi-till-uploaded-total'),
          _stat(context, 'Duplicates', c.uploads ? '${r.duplicateUploads}' : '-',
              'multi-till-duplicates'),
          _stat(context, 'Took', '${took.inSeconds}s', 'multi-till-took'),
        ]),
        if (!ok) ...[
          const SizedBox(height: 16),
          Text(tr(context, 'Problems'), style: theme.textTheme.titleMedium),
          for (final p in r.problems)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('• $p', style: TextStyle(color: theme.colorScheme.error)),
            ),
        ],
        const SizedBox(height: 16),
        Text(tr(context, 'Sales each till holds over the LAN'), style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (var i = 1; i <= c.tills; i++)
            Chip(
              label: Text('POS $i: ${(r.replicated[i] ?? 0)} ${tr(context, 'from other tills')}'),
            ),
        ]),
        const SizedBox(height: 16),
        Text(tr(context, 'Sessions'), style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            key: const Key('multi-till-table'),
            columns: [
              DataColumn(label: Text(tr(context, 'Till'))),
              DataColumn(label: Text(tr(context, 'Session'))),
              DataColumn(label: Text(tr(context, 'Orders')), numeric: true),
              DataColumn(label: Text(tr(context, 'Total')), numeric: true),
              if (c.sendToOdoo) DataColumn(label: Text(tr(context, 'Odoo order'))),
              if (c.uploads) DataColumn(label: Text(tr(context, 'Uploaded')), numeric: true),
              DataColumn(label: Text(tr(context, 'Took')), numeric: true),
            ],
            rows: [
              for (final s in r.sessions)
                DataRow(cells: [
                  DataCell(Text('POS ${s.till}')),
                  DataCell(Text('${s.session}')),
                  DataCell(Text('${s.orders}')),
                  DataCell(Text(s.total.toStringAsFixed(2))),
                  if (c.sendToOdoo)
                    DataCell(Text(
                      s.odooRef ?? s.odooProblem ?? '-',
                      style: s.odooRef == null ? TextStyle(color: theme.colorScheme.error) : null,
                    )),
                  if (c.uploads)
                    DataCell(Text(
                      s.cloudProblem == null ? '${s.uploaded}' : '!',
                      style: s.cloudProblem == null ? null : TextStyle(color: theme.colorScheme.error),
                    )),
                  DataCell(Text('${(s.took.inMilliseconds / 1000).toStringAsFixed(1)}s')),
                ]),
            ],
          ),
        ),
      ],
    );
  }

  Widget _stat(BuildContext context, String label, String value, String key) => Container(
        width: 170,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr(context, label), style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          Text(value, key: Key(key), style: Theme.of(context).textTheme.titleLarge),
        ]),
      );
}
