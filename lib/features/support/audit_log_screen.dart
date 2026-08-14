import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/audit/audit_log.dart';
import '../../core/export/data_export.dart';
import '../../core/export/pdf_export.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';

/// Read-only viewer over the append-only audit trail: every void, cancel,
/// refund, discount and payment a cashier has taken on this till, with who
/// did it and when.
///
/// A manager narrows the trail by event kind, by actor and by date to answer
/// one question at a time ("who voided lines yesterday") rather than scrolling a
/// mixed feed, and can download the filtered rows as a real CSV or PDF file to
/// hand to someone off-site without retyping anything.
class AuditLogScreen extends StatefulWidget {
  const AuditLogScreen({super.key, required this.audit});

  final AuditLog audit;

  @override
  State<AuditLogScreen> createState() => _AuditLogScreenState();
}

class _AuditLogScreenState extends State<AuditLogScreen> {
  String? _event; // null = all events
  String? _actor; // null = all actors
  DateTimeRange? _dates; // null = any date

  List<Map<String, Object?>> get _rows => widget.audit.recent(
        event: _event,
        actor: _actor,
        from: _dates?.start,
        // Include the whole of the end day, not just its midnight.
        to: _dates?.end.add(const Duration(days: 1)),
      );

  /// Icon by event family rather than exact event string, since new event
  /// kinds get added over time and a viewer that only recognised today's list
  /// would silently start showing the fallback icon for anything new.
  IconData _iconFor(String event) {
    if (event.contains('paid') || event.contains('created')) return Icons.payments;
    if (event.contains('refund')) return Icons.undo;
    if (event.contains('void')) return Icons.remove_circle_outline;
    if (event.contains('cancel')) return Icons.cancel_outlined;
    if (event.contains('discount')) return Icons.percent;
    return Icons.info_outline;
  }

  /// Colour by the same event family as [_iconFor], so the icon tint and the
  /// row's accent agree: green for a completed sale, red for anything undone
  /// (refund/void/cancel), amber for a discount, and a neutral grey/blue for
  /// everything else rather than guessing at a colour for events not yet known.
  Color _colorFor(String event) {
    if (event.contains('paid') || event.contains('created')) return AppColors.success;
    if (event.contains('refund') || event.contains('void') || event.contains('cancel')) {
      return AppColors.error;
    }
    if (event.contains('discount')) return AppColors.warning;
    return AppColors.info;
  }

  /// The stored `at` is UTC ISO8601; a manager reading this on the till wants
  /// local wall-clock time, not the UTC one the row was written with.
  String _localTime(String utcAt) {
    final local = DateTime.parse(utcAt).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  /// The filtered rows as a CSV header plus one line per entry, ready for both
  /// the clipboard copy and the downloadable file.
  (List<String>, List<List<String>>) _table(List<Map<String, Object?>> rows) {
    const header = ['id', 'at', 'actor', 'event', 'detail'];
    final data = [
      for (final r in rows)
        [
          '${r['id']}',
          '${r['at']}',
          '${r['actor']}',
          '${r['event']}',
          '${r['detail'] ?? ''}',
        ],
    ];
    return (header, data);
  }

  Future<void> _copyCsv() async {
    final (header, data) = _table(_rows);
    await Clipboard.setData(ClipboardData(text: buildCsv(header, data)));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr(context, 'Audit log copied as CSV'))),
    );
  }

  Future<void> _downloadCsv() async {
    final (header, data) = _table(_rows);
    final name = exportFileName('audit', DateTime.now(), 'csv');
    await _save(() => writeTextExport(name, buildCsv(header, data)));
  }

  Future<void> _downloadPdf() async {
    final (header, data) = _table(_rows);
    final name = exportFileName('audit', DateTime.now(), 'pdf');
    await _save(() async => writeBytesExport(
          name,
          await buildPdfTable(tr(context, 'Audit log'), header, data),
        ));
  }

  /// Runs a file-writing action and tells the user where it landed, or that it
  /// could not be saved, rather than failing silently.
  Future<void> _save(Future<String> Function() write) async {
    try {
      final path = await write();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${tr(context, 'Saved to')}: $path')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr(context, 'Could not save file'))),
      );
    }
  }

  Future<void> _pickDates() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 2),
      lastDate: now,
      initialDateRange: _dates,
    );
    if (!mounted) return;
    if (picked != null) setState(() => _dates = picked);
  }

  String _dateLabel() {
    if (_dates == null) return tr(context, 'Any date');
    final s = _dates!.start;
    final e = _dates!.end;
    return '${s.month}/${s.day} - ${e.month}/${e.day}';
  }

  @override
  Widget build(BuildContext context) {
    final events = widget.audit.events();
    final actors = widget.audit.actors();
    final rows = _rows;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Audit log')),
        actions: [
          IconButton(
            key: const Key('audit-export'),
            tooltip: tr(context, 'Copy CSV'),
            icon: const Icon(Icons.copy_all),
            onPressed: _copyCsv,
          ),
          IconButton(
            key: const Key('audit-download-csv'),
            tooltip: tr(context, 'Download CSV'),
            icon: const Icon(Icons.download),
            onPressed: _downloadCsv,
          ),
          IconButton(
            key: const Key('audit-download-pdf'),
            tooltip: tr(context, 'Download PDF'),
            icon: const Icon(Icons.picture_as_pdf_outlined),
            onPressed: _downloadPdf,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String?>(
                        key: const Key('audit-filter'),
                        initialValue: _event,
                        decoration: InputDecoration(
                          labelText: tr(context, 'Event'),
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: [
                          DropdownMenuItem<String?>(
                            value: null,
                            child: Text(tr(context, 'All events')),
                          ),
                          for (final e in events)
                            DropdownMenuItem<String?>(value: e, child: Text(e)),
                        ],
                        onChanged: (v) => setState(() => _event = v),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<String?>(
                        key: const Key('audit-actor-filter'),
                        initialValue: _actor,
                        decoration: InputDecoration(
                          labelText: tr(context, 'Actor'),
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: [
                          DropdownMenuItem<String?>(
                            value: null,
                            child: Text(tr(context, 'All actors')),
                          ),
                          for (final a in actors)
                            DropdownMenuItem<String?>(value: a, child: Text(a)),
                        ],
                        onChanged: (v) => setState(() => _actor = v),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('audit-date-filter'),
                        icon: const Icon(Icons.date_range, size: 18),
                        label: Text(_dateLabel()),
                        onPressed: _pickDates,
                      ),
                    ),
                    if (_dates != null)
                      IconButton(
                        key: const Key('audit-date-clear'),
                        tooltip: tr(context, 'Clear'),
                        icon: const Icon(Icons.clear),
                        onPressed: () => setState(() => _dates = null),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: rows.isEmpty
                ? Center(child: Text(tr(context, 'No audit entries')))
                : ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (context, index) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final r = rows[i];
                      final event = r['event'] as String;
                      final actor = r['actor'] as String;
                      final detail = r['detail'] as String?;
                      final color = _colorFor(event);
                      return Container(
                        decoration: BoxDecoration(
                          border: Border(left: BorderSide(color: color, width: 3)),
                        ),
                        child: ListTile(
                          key: Key('audit-row-${r['id']}'),
                          leading: Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(_iconFor(event), color: color, size: 20),
                          ),
                          title: Text('${_localTime(r['at'] as String)}  $event'),
                          subtitle: Text(detail == null
                              ? '${tr(context, 'Actor')}: $actor'
                              : '${tr(context, 'Actor')}: $actor\n$detail'),
                          isThreeLine: detail != null,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
