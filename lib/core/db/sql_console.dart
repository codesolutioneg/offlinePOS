import 'package:sqlite3/sqlite3.dart';

import 'database.dart';

/// One statement run against the till's SQLCipher file.
///
/// Reads return [columns] and [rows]. Writes return [changes]. [blocked] is a
/// statement that would reach the encryption key, attach another file or rewrite
/// the audit trail, which this console never does.
class SqlRunResult {
  const SqlRunResult({
    this.columns = const [],
    this.rows = const [],
    this.changes,
    this.error,
    this.blocked = false,
    this.truncated = false,
    this.readOnly = false,
  });

  final List<String> columns;
  final List<List<String>> rows;
  final int? changes;
  final String? error;
  final bool blocked;
  final bool truncated;

  /// Whether the statement only read, as [SqlConsole.isRead] judged it.
  final bool readOnly;

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
  ///
  /// Asked of SQLite rather than guessed from the first keyword: a `WITH` can
  /// front a DELETE, and only the compiled statement knows. Anything that does
  /// not compile counts as a write, so it still meets the confirm. SQLite calls a
  /// pragma that sets a value, or a transaction statement, read-only too, yet
  /// both change the connection every screen shares, so they count as writes.
  bool isRead(String sql) {
    final trimmed = sql.trim();
    if (trimmed.isEmpty) return false;
    final t = _plain(trimmed);
    if (RegExp(r'^(BEGIN|COMMIT|END|ROLLBACK|SAVEPOINT|RELEASE)\b').hasMatch(t)) {
      return false;
    }
    final pragma = RegExp(r'^PRAGMA\s+(\w+\s*\.\s*)?(\w+)\s*(\S?)').firstMatch(t);
    if (pragma != null) {
      final arg = pragma.group(3);
      if (arg == '=') return false;
      if (arg == '(' && !_readPragmas.contains(pragma.group(2))) return false;
    }
    PreparedStatement? stmt;
    try {
      stmt = _db.raw.prepare(trimmed, checkNoTail: true);
      return stmt.isReadOnly;
    } catch (_) {
      return false;
    } finally {
      stmt?.dispose();
    }
  }

  /// Pragmas whose argument names what to look at rather than a value to set.
  static const _readPragmas = {
    'TABLE_INFO',
    'TABLE_XINFO',
    'TABLE_LIST',
    'INDEX_LIST',
    'INDEX_INFO',
    'INDEX_XINFO',
    'FOREIGN_KEY_LIST',
    'FOREIGN_KEY_CHECK',
    'INTEGRITY_CHECK',
    'QUICK_CHECK',
  };

  SqlRunResult run(String sql) {
    final trimmed = sql.trim();
    if (trimmed.isEmpty) {
      return const SqlRunResult(error: 'Type a statement first.');
    }
    final read = isRead(trimmed);
    if (_blocked(trimmed, read)) {
      return const SqlRunResult(
        blocked: true,
        error: 'That statement is not allowed here.',
      );
    }
    PreparedStatement? stmt;
    try {
      stmt = _db.raw.prepare(trimmed, checkNoTail: true);
      // select works for reads and for writes with RETURNING; a pure write comes
      // back with no column names and we report how many rows changed instead.
      final rs = stmt.select();
      if (rs.columnNames.isNotEmpty) {
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
          readOnly: read,
        );
      }
      return SqlRunResult(changes: _db.raw.updatedRows, readOnly: read);
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

  /// [sql] in upper case with comments gone and identifier or string quotes
  /// dropped, so `PRAGMA "rekey"` or `PRAGMA/**/rekey` reads as `PRAGMA REKEY`.
  static String _plain(String sql) {
    final out = StringBuffer();
    var i = 0;
    while (i < sql.length) {
      final c = sql[i];
      if (sql.startsWith('--', i)) {
        final nl = sql.indexOf('\n', i);
        i = nl < 0 ? sql.length : nl;
        out.write(' ');
      } else if (sql.startsWith('/*', i)) {
        final end = sql.indexOf('*/', i + 2);
        i = end < 0 ? sql.length : end + 2;
        out.write(' ');
      } else if (c == "'" || c == '"' || c == '`' || c == '[') {
        final close = c == '[' ? ']' : c;
        final end = sql.indexOf(close, i + 1);
        final stop = end < 0 ? sql.length : end;
        out.write(' ${sql.substring(i + 1, stop)} ');
        i = stop + 1;
      } else {
        out.write(c);
        i++;
      }
    }
    return out.toString().trim().replaceAll(RegExp(r'\s+'), ' ').toUpperCase();
  }

  static bool _blocked(String sql, bool readOnly) {
    final t = _plain(sql);
    if (RegExp(r'\bATTACH\b').hasMatch(t)) return true;
    // `VACUUM main INTO` writes a copy as surely as `VACUUM INTO`.
    if (RegExp(r'\bVACUUM\b.*\bINTO\b').hasMatch(t)) return true;
    // With or without a schema prefix: `PRAGMA main.key` reaches the key too.
    if (RegExp(r'\bPRAGMA\s+(\w+\s*\.\s*)?(KEY|REKEY|CIPHER\w*|WRITABLE_SCHEMA)\b')
        .hasMatch(t)) {
      return true;
    }
    // The audit trail is the record of what this console did, so nothing typed
    // here may change it.
    if (!readOnly && RegExp(r'\bAUDIT_LOG\b').hasMatch(t)) return true;
    return false;
  }

  static bool _safeIdent(String name) =>
      RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name);
}
