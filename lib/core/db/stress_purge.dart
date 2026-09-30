import 'database.dart';

/// The note every Stress Lab order carries. Cleanup keys on it and nothing else.
const String kStressNote = '[STRESS]';

const _noteMatch = '%"note":"$kStressNote"%';

/// Remove every Stress Lab order on this till, its own and the copies replicated
/// from other tills, with anything still queued for them. Returns how many went.
int purgeStressOrders(Db db) {
  final uuids = db.raw
      .select('SELECT uuid FROM orders WHERE payload LIKE ?', [_noteMatch])
      .map((r) => r['uuid'] as String)
      .toList();
  if (uuids.isEmpty) return 0;
  void remove() {
    for (final u in uuids) {
      db.raw.execute('DELETE FROM outbox WHERE payload_uuid = ?', [u]);
      db.raw.execute('DELETE FROM orders WHERE uuid = ?', [u]);
    }
  }

  if (!db.raw.autocommit) {
    remove();
    return uuids.length;
  }
  db.raw.execute('BEGIN');
  try {
    remove();
    db.raw.execute('COMMIT');
  } catch (_) {
    db.raw.execute('ROLLBACK');
    rethrow;
  }
  return uuids.length;
}
