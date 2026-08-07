import 'dart:typed_data';

/// A receipt that was built but never reached paper.
class SpooledJob {
  const SpooledJob({
    required this.id,
    required this.bytes,
    required this.createdAt,
    this.reference,
    this.attempts = 0,
    this.lastError,
  });

  final int id;
  final Uint8List bytes;
  final DateTime createdAt;

  /// The order this belongs to, so support can say which sale has no paper.
  final String? reference;

  final int attempts;
  final String? lastError;
}

/// Where held receipts wait for the printer to come back.
///
/// One instance per printer name. Whether that survives a restart is the whole
/// question: a spool that does not is only recoverable until closing time, which
/// is exactly when a till gets restarted.
abstract interface class SpoolStore {
  Future<void> add(Uint8List bytes, {String? reference});

  /// Oldest first, because a kitchen reading tickets out of order is worse than
  /// reading them late.
  Future<List<SpooledJob>> oldestFirst({int limit});

  Future<void> remove(int id);

  Future<void> markFailed(int id, String error);

  /// Drops the oldest jobs until at most [keep] remain and returns what went, so
  /// no receipt is ever discarded without somebody being told.
  Future<List<SpooledJob>> trimTo(int keep);

  int get count;
}

/// A spool that lives only as long as the process.
///
/// For tests, and for a caller that genuinely has no database. Anything on a till
/// should use the durable one.
class MemorySpoolStore implements SpoolStore {
  final List<SpooledJob> _jobs = [];
  int _nextId = 1;

  @override
  Future<void> add(Uint8List bytes, {String? reference}) async {
    _jobs.add(SpooledJob(
      id: _nextId++,
      bytes: bytes,
      createdAt: DateTime.now().toUtc(),
      reference: reference,
    ));
  }

  @override
  Future<List<SpooledJob>> oldestFirst({int limit = 50}) async =>
      _jobs.take(limit).toList();

  @override
  Future<void> remove(int id) async => _jobs.removeWhere((j) => j.id == id);

  @override
  Future<void> markFailed(int id, String error) async {
    final i = _jobs.indexWhere((j) => j.id == id);
    if (i < 0) return;
    final job = _jobs[i];
    _jobs[i] = SpooledJob(
      id: job.id,
      bytes: job.bytes,
      createdAt: job.createdAt,
      reference: job.reference,
      attempts: job.attempts + 1,
      lastError: error,
    );
  }

  @override
  Future<List<SpooledJob>> trimTo(int keep) async {
    final dropped = <SpooledJob>[];
    while (_jobs.length > keep) {
      dropped.add(_jobs.removeAt(0));
    }
    return dropped;
  }

  @override
  int get count => _jobs.length;
}
