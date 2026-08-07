/// Versioned schema.
///
/// Migrations are additive first. A till can be holding unsynced sales when it
/// updates, so a destructive migration is only acceptable one release after the
/// replacement column is proven to be populated.
class Schema {
  static const int version = 1;

  /// Applied in order. Index i upgrades the database from version i to i+1.
  static const List<List<String>> migrations = [
    // v0 -> v1
    [
      '''
      CREATE TABLE orders (
        uuid        TEXT PRIMARY KEY,
        device_id   TEXT NOT NULL,
        cashier_id  TEXT NOT NULL,
        created_at  TEXT NOT NULL,
        state       TEXT NOT NULL,
        server_id   INTEGER,
        total       REAL NOT NULL DEFAULT 0,
        payload     TEXT NOT NULL
      )
      ''',
      'CREATE INDEX idx_orders_state ON orders(state)',
      'CREATE INDEX idx_orders_created ON orders(created_at)',
      '''
      CREATE TABLE outbox (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        kind         TEXT NOT NULL,
        payload_uuid TEXT NOT NULL,
        payload      TEXT NOT NULL,
        attempts     INTEGER NOT NULL DEFAULT 0,
        last_error   TEXT,
        sent_at      TEXT,
        created_at   TEXT NOT NULL
      )
      ''',
      // Delivery is ordered, so the drain reads by id with sent_at IS NULL.
      'CREATE INDEX idx_outbox_pending ON outbox(sent_at, id)',
      // One live entry per (kind, uuid): re-queuing the same order must update,
      // not stack up duplicates the server has to deduplicate later.
      'CREATE UNIQUE INDEX idx_outbox_identity ON outbox(kind, payload_uuid)',
      '''
      CREATE TABLE audit_log (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        at         TEXT NOT NULL,
        actor      TEXT NOT NULL,
        event      TEXT NOT NULL,
        detail     TEXT,
        synced_at  TEXT
      )
      ''',
      'CREATE INDEX idx_audit_unsynced ON audit_log(synced_at, id)',
    ],
  ];
}
