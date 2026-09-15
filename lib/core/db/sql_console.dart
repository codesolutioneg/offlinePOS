import 'package:sqlite3/sqlite3.dart';

import 'database.dart';

/// One statement run against the till's SQLCipher file.
///
/// Reads return [columns] and [rows]. Writes return [changes]. [blocked] is a
/// statement that would reach the encryption key or attach another file, which
/// this console never does.
class SqlRunResult {
  const SqlRunResult({
    this.columns = const [],
    this.rows = const [],
    this.changes,
    this.error,
    this.blocked = false,
    this.truncated = false,
  });

  final List<String> columns;
  final List<List<String>> rows;
  final int? changes;
  final String? error;
  final bool blocked;
  final bool truncated;

  bool get ok => error == null && !blocked;
}

/// Run ad-hoc SQL on the live till database.
///
/// One statement at a time, against the connection the app already holds, so a
/// manager inspecting `pos_tables` sees the same rows the floor is drawing.
class SqlConsole {
  SqlConsole(this._db, {this.rowCap = 500});

  final Db _db;
  final int rowCap;

  /// User tables and views, never sqlite internals.
  List<String> tables() => [
        for (final r in _db.raw.select(
          "SELECT name FROM sqlite_master "
          "WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' "
          "ORDER BY name",
        ))
          '${r['name']}',
      ];

  /// Columns of [table] in declaration order, for a peek before writing.
  List<String> columnsOf(String table) {
    final name = table.trim();
    if (name.isEmpty || !_safeIdent(name)) return const [];
    return [
      for (final r in _db.raw.select('PRAGMA table_info("$name")')) '${r['name']}',
    ];
  }

  /// A SELECT that fills the editor when a table is tapped.
  String previewSql(String table) => 'SELECT * FROM "${table.trim()}" LIMIT $rowCap;';

  /// Whether [sql] only reads. Writes need a confirm in the window before they run.
  bool isRead(String sql) {
    final t = _lead(sql);
    if (t.startsWith('SELECT') || t.startsWith('WITH') || t.startsWith('EXPLAIN')) {
      return true;
    }
    if (t.startsWith('PRAGMA')) {
      return !t.contains('=');
    }
    return false;
  }

  SqlRunResult run(String sql) {
    final trimmed = sql.trim();
    if (trimmed.isEmpty) {
      return const SqlRunResult(error: 'Type a statement first.');
    }
    if (_blocked(trimmed)) {
      return const SqlRunResult(
        blocked: true,
        error: 'That statement is not allowed here.',
      );
    }
    PreparedStatement? stmt;
    try {
      stmt = _db.raw.prepare(trimmed);
      if (stmt.columnCount > 0) {
        final rs = stmt.select();
        final cols = List<String>.of(rs.columnNames);
        final rows = <List<String>>[];
        var truncated = false;
        for (final row in rs) {
          if (rows.length >= rowCap) {
            truncated = true;
            break;
          }
          rows.add([for (final v in row.values) _cell(v)]);
        }
        return SqlRunResult(
          columns: cols,
          rows: rows,
          truncated: truncated,
        );
      }
      stmt.execute();
      return SqlRunResult(changes: _db.raw.updatedRows);
    } on SqliteException catch (e) {
      return SqlRunResult(error: e.message);
    } catch (e) {
      return SqlRunResult(error: '$e');
    } finally {
      stmt?.dispose();
    }
  }

  static String _cell(Object? v) {
    if (v == null) return '';
    if (v is List<int>) {
      final n = v.length < 24 ? v.length : 24;
      final hex = [
        for (final b in v.take(n)) b.toRadixString(16).padLeft(2, '0'),
      ].join();
      return v.length > n ? 'blob:$hex…' : 'blob:$hex';
    }
    return '$v';
  }

  static String _lead(String sql) {
    var s = sql.trimLeft();
    while (s.startsWith('--')) {
      final nl = s.indexOf('\n');
      if (nl < 0) return '';
      s = s.substring(nl + 1).trimLeft();
    }
    return s.replaceAll(RegExp(r'\s+'), ' ').toUpperCase();
  }

  static bool _blocked(String sql) {
    final t = _lead(sql);
    if (RegExp(r'\bATTACH\b').hasMatch(t)) return true;
    if (t.contains('VACUUM INTO')) return true;
    if (RegExp(r'\bPRAGMA\s+(KEY|REKEY|CIPHER)\b').hasMatch(t)) return true;
    return false;
  }

  static bool _safeIdent(String name) =>
      RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name);
}
