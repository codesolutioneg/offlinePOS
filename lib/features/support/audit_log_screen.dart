import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/audit/audit_log.dart';
import '../../core/i18n/l10n.dart';

/// Read-only viewer over the append-only audit trail: every void, cancel,
/// refund, discount and payment a cashier has taken on this till, with who
/// did it and when.
///
/// A manager filters by event kind to answer one question at a time ("who
/// voided lines today") rather than scrolling a mixed feed, and can export the
/// filtered rows as CSV to hand to someone off-site without retyping anything.
class AuditLogScreen extends StatefulWidget {
  const AuditLogScreen({super.key, required this.audit});

  final AuditLog audit;

  @override
  State<AuditLogScreen> createState() => _AuditLogScreenState();
}

class _AuditLogScreenState extends State<AuditLogScreen> {
  String? _event; // null = all events

  List<Map<String, Object?>> get _rows => widget.audit.recent(event: _event);

  /// Icon by event family rather than exact event string, since new event
  /// kinds get added over time and a viewer that only recognised today's list
  /// would silently start showing the fallback icon for anything new.
  IconData _iconFor(String event) {
    if (event.contains('paid')) return Icons.payments;
    if (event.contains('refund')) return Icons.undo;
    if (event.contains('void')) return Icons.remove_circle_outline;
    if (event.contains('cancel')) return Icons.cancel_outlined;
    if (event.contains('discount')) return Icons.percent;
    return Icons.info_outline;
  }

  /// The stored `at` is UTC ISO8601; a manager reading this on the till wants
  /// local wall-clock time, not the UTC one the row was written with.
  String _localTime(String utcAt) {
    final local = DateTime.parse(utcAt).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  String _csvField(String value) {
    if (value.contains(',') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }

  String _buildCsv(List<Map<String, Object?>> rows) {
    final lines = <String>['id,at,actor,event,detail'];
    for (final r in rows) {
      lines.add([
        '${r['id']}',
        '${r['at']}',
        '${r['actor']}',
        '${r['event']}',
        '${r['detail'] ?? ''}',
      ].map(_csvField).join(','));
    }
    return lines.join('\n');
  }

  Future<void> _exportCsv() async {
    final csv = _buildCsv(_rows);
    await Clipboard.setData(ClipboardData(text: csv));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr(context, 'Audit log copied as CSV'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final events = widget.audit.events();
    final rows = _rows;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Audit log')),
        actions: [
          IconButton(
            key: const Key('audit-export'),
            tooltip: tr(context, 'Export CSV'),
            icon: const Icon(Icons.copy_all),
            onPressed: _exportCsv,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
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
                for (final e in events) DropdownMenuItem<String?>(value: e, child: Text(e)),
              ],
              onChanged: (v) => setState(() => _event = v),
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
                      return ListTile(
                        key: Key('audit-row-${r['id']}'),
                        leading: Icon(_iconFor(event)),
                        title: Text('${_localTime(r['at'] as String)}  $event'),
                        subtitle: Text(detail == null
                            ? '${tr(context, 'Actor')}: $actor'
                            : '${tr(context, 'Actor')}: $actor\n$detail'),
                        isThreeLine: detail != null,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
