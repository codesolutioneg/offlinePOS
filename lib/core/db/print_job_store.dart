import 'dart:typed_data';

import '../printing/spool_store.dart';
import 'database.dart';

/// Held receipts on disk, for one named printer.
///
/// In the database rather than in memory for the same reason the outbox is: a till
/// is restarted nightly, and a rush spent with the printer switched off would
/// otherwise lose every receipt it held at the moment someone closed the app.
class SqlitePrintJobStore implements SpoolStore {
  SqlitePrintJobStore(this._db, {required this.printer, DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final Db _db;

  /// The stable name a receipt is routed by, never an address.
  final String printer;

  final DateTime Function() _now;

  @override
  Future<void> add(Uint8List bytes, {String? reference}) async {
    _db.raw.execute(
      'INSERT INTO print_jobs (printer, bytes, reference, created_at) VALUES (?,?,?,?)',
      [printer, bytes, reference, _now().toUtc().toIso8601String()],
    );
  }

  @override
  Future<List<SpooledJob>> oldestFirst({int limit = 50}) async => _db.raw
      .select(
        'SELECT id, bytes, reference, created_at, attempts, last_error '
        'FROM print_jobs WHERE printer = ? ORDER BY id LIMIT ?',
        [printer, limit],
      )
      .map(_map)
      .toList();

  @override
  Future<void> remove(int id) async =>
      _db.raw.execute('DELETE FROM print_jobs WHERE id = ?', [id]);

  @override
  Future<void> markFailed(int id, String error) async => _db.raw.execute(
        'UPDATE print_jobs SET attempts = attempts + 1, last_error = ? WHERE id = ?',
        [error, id],
      );

  @override
  Future<List<SpooledJob>> trimTo(int keep) async {
    final excess = count - keep;
    if (excess <= 0) return const [];
    final doomed = _db.raw.select(
      'SELECT id, bytes, reference, created_at, attempts, last_error '
      'FROM print_jobs WHERE printer = ? ORDER BY id LIMIT ?',
      [printer, excess],
    ).map(_map).toList();
    for (final job in doomed) {
      await remove(job.id);
    }
    return doomed;
  }

  @override
  int get count => _db.raw
      .select('SELECT COUNT(*) c FROM print_jobs WHERE printer = ?', [printer])
      .first['c'] as int;

  SpooledJob _map(Map<String, Object?> r) => SpooledJob(
        id: r['id'] as int,
        bytes: r['bytes'] as Uint8List,
        createdAt: DateTime.parse(r['created_at'] as String),
        reference: r['reference'] as String?,
        attempts: r['attempts'] as int,
        lastError: r['last_error'] as String?,
      );
}
