import 'database.dart';

/// The note every Stress Lab order carries. Cleanup keys on it and nothing else.
const String kStressNote = '[STRESS]';

/// How a lab order's note reads inside its stored json (`orders.payload`,
/// `outbox.payload`), for a LIKE match.
const String kStressNoteMatch = '%"note":"$kStressNote"%';

/// Every Stress Lab order on this till, its own and the copies from other tills.
List<String> stressOrderUuids(Db db) => db.raw
    .select('SELECT uuid FROM orders WHERE payload LIKE ?', [kStressNoteMatch])
    .map((r) => r['uuid'] as String)
    .toList();

/// How many Stress Lab orders are on this till. A shift does not close over any.
int stressOrderCount(Db db) =>
    db.raw.select('SELECT COUNT(*) c FROM orders WHERE payload LIKE ?', [
          kStressNoteMatch,
        ]).first['c']
        as int;

/// Remove every Stress Lab order on this till, its own and the copies replicated
/// from other tills, with anything still queued for them. Returns how many went.
///
/// A driver's bag is queued under `uuid|driverId`, so the queue is matched on
/// that prefix too.
int purgeStressOrders(Db db) {
  final uuids = stressOrderUuids(db);
  if (uuids.isEmpty) return 0;
  void remove() {
    for (final u in uuids) {
      db.raw.execute(
        'DELETE FROM outbox WHERE payload_uuid = ? OR payload_uuid LIKE ?',
        [u, '$u|%'],
      );
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
