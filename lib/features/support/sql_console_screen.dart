import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/audit/audit_log.dart';
import '../../core/db/database.dart';
import '../../core/db/sql_console.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';

/// A window onto the live SQLCipher file: pick a table, run SQL, see the rows.
///
/// This is the till's own database, not a copy. A write here is what the floor,
/// the cart and the next sync will read. Gated by settings, because it can change
/// money and occupancy as easily as it can list them.
class SqlConsoleScreen extends StatefulWidget {
  const SqlConsoleScreen({
    super.key,
    required this.db,
    this.audit,
    this.cashierId,
  });

  final Db db;
  final AuditLog? audit;
  final String? cashierId;

  @override
  State<SqlConsoleScreen> createState() => _SqlConsoleScreenState();
}

class _SqlConsoleScreenState extends State<SqlConsoleScreen> {
  late final SqlConsole _sql;
  late final TextEditingController _input;
  late List<String> _tables;
  String? _table;
  SqlRunResult? _result;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _sql = SqlConsole(widget.db);
    _tables = _sql.tables();
    _input = TextEditingController(
      text: _tables.contains('pos_tables')
          ? _sql.previewSql('pos_tables')
          : 'SELECT name, type FROM sqlite_master ORDER BY name;',
    );
    if (_tables.contains('pos_tables')) _table = 'pos_tables';
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final sql = _input.text.trim();
    if (sql.isEmpty) return;
    if (!_sql.isRead(sql)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          key: const Key('sql-write-confirm'),
          title: Text(tr(ctx, 'Run this write?')),
          content: Text(tr(ctx,
              'This changes the live till database. The floor and the next sale will see it.')),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(tr(ctx, 'Cancel'))),
            FilledButton(
              key: const Key('sql-write-ok'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr(ctx, 'Run')),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() => _running = true);
    final result = _sql.run(sql);
    widget.audit?.record(
      widget.cashierId ?? 'system',
      result.blocked
          ? 'sql.blocked'
          : result.ok
              ? (_sql.isRead(sql) ? 'sql.select' : 'sql.write')
              : 'sql.error',
      detail: sql.length > 240 ? '${sql.substring(0, 240)}…' : sql,
    );
    if (!mounted) return;
    setState(() {
      _running = false;
      _result = result;
      _tables = _sql.tables();
    });
  }

  void _openTable(String name) {
    setState(() {
      _table = name;
      _input.text = _sql.previewSql(name);
      _result = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'SQL console')),
        actions: [
          IconButton(
            key: const Key('sql-copy'),
            tooltip: tr(context, 'Copy SQL'),
            onPressed: () => Clipboard.setData(ClipboardData(text: _input.text)),
            icon: const Icon(Icons.copy),
          ),
        ],
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 220,
            child: Material(
              color: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest
                  .withValues(alpha: 0.5),
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Text(tr(context, 'Tables'),
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  for (final t in _tables)
                    ListTile(
                      dense: true,
                      selected: t == _table,
                      key: Key('sql-table-$t'),
                      title: Text(t, overflow: TextOverflow.ellipsis),
                      onTap: () => _openTable(t),
                    ),
                ],
              ),
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(tr(context,
                      'The encrypted till database. A write is live, not a copy.'),
                      style: TextStyle(
                          fontSize: 12, color: AppColors.textMutedLight)),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 140,
                    child: TextField(
                      key: const Key('sql-input'),
                      controller: _input,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      style: const TextStyle(
                          fontFamily: 'Consolas', fontSize: 13, height: 1.35),
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(),
                        hintText: 'SELECT * FROM pos_tables;',
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(children: [
                    FilledButton.icon(
                      key: const Key('sql-run'),
                      onPressed: _running ? null : _run,
                      icon: const Icon(Icons.play_arrow),
                      label: Text(_running
                          ? tr(context, 'Running...')
                          : tr(context, 'Run')),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      key: const Key('sql-clear'),
                      onPressed: () => setState(() {
                        _input.clear();
                        _result = null;
                      }),
                      child: Text(tr(context, 'Clear')),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  Expanded(child: _resultPane()),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultPane() {
    final r = _result;
    if (r == null) {
      return Center(
        child: Text(tr(context, 'Run a statement to see rows.'),
            style: TextStyle(color: AppColors.textMutedLight)),
      );
    }
    if (!r.ok) {
      return Align(
        alignment: Alignment.topLeft,
        child: SelectableText(
          r.error ?? '',
          key: const Key('sql-error'),
          style: const TextStyle(color: AppColors.error, fontFamily: 'Consolas'),
        ),
      );
    }
    if (r.columns.isEmpty) {
      return Align(
        alignment: Alignment.topLeft,
        child: Text(
          '${tr(context, 'Done.')} ${r.changes ?? 0} ${tr(context, 'row(s) changed')}',
          key: const Key('sql-changes'),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${r.rows.length} ${tr(context, 'row(s)')}'
          '${r.truncated ? ' — ${tr(context, 'truncated')}' : ''}',
          key: const Key('sql-row-count'),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Scrollbar(
            thumbVisibility: true,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SingleChildScrollView(
                child: DataTable(
                  headingRowHeight: 36,
                  dataRowMinHeight: 32,
                  dataRowMaxHeight: 48,
                  columns: [
                    for (final c in r.columns)
                      DataColumn(
                        label: Text(c,
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                      ),
                  ],
                  rows: [
                    for (final row in r.rows)
                      DataRow(cells: [
                        for (final cell in row)
                          DataCell(SelectableText(cell,
                              style: const TextStyle(
                                  fontFamily: 'Consolas', fontSize: 12))),
                      ]),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
