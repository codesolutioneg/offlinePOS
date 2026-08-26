import 'database.dart';

/// Write a local change and announce it to the LAN fabric in the same transaction, so
/// a record cannot be announced as changed unless it really changed.
///
/// [announce] is null on a till with the fabric off, and then this is a bare write on
/// exactly the code path a one-till shop always ran.
///
/// A failed announce still commits. That is the deliberate half: the record in front
/// of whoever is standing at the till is the one they just wrote, and refusing their
/// edit because a peer device misbehaved would be the wrong way round. The shop finds
/// out through the publish-failure audit line instead.
///
/// One helper rather than a copy in every store, because four stores were writing the
/// same six lines and a divergence between them would be a shop whose devices quietly
/// stopped agreeing.
void announcedWrite(Db db, void Function() write, void Function()? announce) {
  if (announce == null) {
    write();
    return;
  }
  db.raw.execute('BEGIN');
  try {
    write();
    announce();
    db.raw.execute('COMMIT');
  } catch (_) {
    db.raw.execute('ROLLBACK');
    write();
  }
}
