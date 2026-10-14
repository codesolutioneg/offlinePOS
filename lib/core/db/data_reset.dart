import 'dart:io';

import 'database.dart';

/// This till's database, deleted at the next launch.
///
/// The running till holds pos.db open, so it cannot be removed in place. A marker
/// is written beside it instead, and [apply] deletes the database at start-up,
/// before anything opens it. Unlike a cloud restore nothing is kept: this is for a
/// till that was set up to be tried and is now handed over clean, and a copy left
/// on disk would be the trial's sales still sitting on the customer's machine.
///
/// The database key stays in the keychain. The fresh database is encrypted under
/// it again, which is safe: there is nothing left that it opens.
class PendingReset {
  PendingReset(this.databasePath);

  final String databasePath;

  String get _marker => '$databasePath.reset';

  bool get isStaged => File(_marker).existsSync();

  Future<void> stage() async {
    await File(_marker).writeAsString(DateTime.now().toUtc().toIso8601String(),
        flush: true);
  }

  Future<void> cancel() async {
    final marker = File(_marker);
    if (marker.existsSync()) await marker.delete();
  }

  /// Delete the database when a reset was staged. Returns whether it was.
  ///
  /// The marker goes last, so a launch interrupted half way deletes what is left on
  /// the next one instead of opening a database with its journal gone.
  Future<bool> apply() async {
    final marker = File(_marker);
    if (!marker.existsSync()) return false;
    for (final suffix in const ['', '-wal', '-shm', '-journal', '.restore']) {
      final file = File('$databasePath$suffix');
      if (file.existsSync()) await file.delete();
    }
    await marker.delete();
    return true;
  }
}

/// The LAN event kinds that describe a sale or the floor it sat on, by wire name.
/// Kept in step with `LanEventKind`; listed here so the db layer does not reach up
/// into the fabric.
const List<String> kOrderEventKinds = [
  'order.upsert',
  'kitchen.status',
  'order.claim',
  'table.assignment',
  'shift.lifecycle',
];

/// What [wipeOrderHistory] removed, for the audit trail and the confirmation.
typedef HistoryWipe = ({int orders, int shifts});

/// Remove every sale this till holds, and everything that only exists because of
/// one: its queue to Odoo and to the reports site, its kitchen and receipt prints,
/// the shifts and their Z reports, who had which table, and this till's own LAN
/// events about them. The menu, staff, printers, floor plan, settings and pairing
/// stay.
///
/// With [before], only what started before that moment goes. A till that hears
/// about a wipe late must not lose the sales it rang after it.
///
/// This till's own order events go too: a secondary that joins later reads the
/// whole log from the start, and would otherwise bring the wiped sales back.
HistoryWipe wipeOrderHistory(Db db, {DateTime? before}) {
  final cut = before?.toUtc();
  bool earlier(Object? at) {
    if (cut == null) return true;
    final parsed = DateTime.tryParse('$at');
    return parsed == null || parsed.toUtc().isBefore(cut);
  }

  final orderUuids = [
    for (final r in db.raw.select('SELECT uuid, created_at FROM orders'))
      if (earlier(r['created_at'])) r['uuid'] as String,
  ];
  final shiftIds = [
    for (final r in db.raw.select('SELECT id, opened_at FROM shifts'))
      if (earlier(r['opened_at'])) r['id'] as String,
  ];
  final eventSeqs = [
    for (final r in db.raw.select(
        'SELECT seq, at FROM lan_events WHERE kind IN '
        '(${List.filled(kOrderEventKinds.length, '?').join(',')})',
        kOrderEventKinds))
      if (earlier(r['at'])) r['seq'] as int,
  ];

  void remove() {
    for (final u in orderUuids) {
      db.raw.execute(
        'DELETE FROM outbox WHERE payload_uuid = ? OR payload_uuid LIKE ?',
        [u, '$u|%'],
      );
      db.raw.execute('DELETE FROM orders WHERE uuid = ?', [u]);
      db.raw.execute(
          "DELETE FROM cloud_pending WHERE kind = 'order' AND key = ?", [u]);
      db.raw.execute('DELETE FROM lan_clocks WHERE record_uuid = ?', [u]);
    }
    for (final id in shiftIds) {
      db.raw.execute('DELETE FROM shifts WHERE id = ?', [id]);
      db.raw.execute(
          "DELETE FROM cloud_pending WHERE kind = 'shift' AND key = ?", [id]);
    }
    for (final seq in eventSeqs) {
      db.raw.execute('DELETE FROM lan_events WHERE seq = ?', [seq]);
    }
    if (cut == null) db.raw.execute('DELETE FROM outbox');
    db.raw.execute('DELETE FROM print_jobs');
    db.raw.execute('DELETE FROM table_assignments');
  }

  if (!db.raw.autocommit) {
    remove();
  } else {
    db.raw.execute('BEGIN');
    try {
      remove();
      db.raw.execute('COMMIT');
    } catch (_) {
      db.raw.execute('ROLLBACK');
      rethrow;
    }
  }
  return (orders: orderUuids.length, shifts: shiftIds.length);
}
