/// Versioned schema.
///
/// Migrations are additive first. A till can be holding unsynced sales when it
/// updates, so a destructive migration is only acceptable one release after the
/// replacement column is proven to be populated.
class Schema {
  static const int version = 3;

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

    // v1 -> v2: the catalogue.
    //
    // This is the table Odoo's POS never writes, and the reason it cannot start
    // without the network: orders persist, the things you sell do not. Holding the
    // catalogue locally is the whole point of this app, so it is a first-class table
    // and not a cache someone can decide to skip.
    [
      '''
      CREATE TABLE categories (
        id       INTEGER PRIMARY KEY,
        name     TEXT NOT NULL,
        sequence INTEGER NOT NULL DEFAULT 0,
        parent_id INTEGER
      )
      ''',
      '''
      CREATE TABLE products (
        id           INTEGER PRIMARY KEY,
        name         TEXT NOT NULL,
        price        REAL NOT NULL DEFAULT 0,
        category_id  INTEGER,
        barcode      TEXT,
        active       INTEGER NOT NULL DEFAULT 1,
        sold_by_weight INTEGER NOT NULL DEFAULT 0,
        tax_rate     REAL NOT NULL DEFAULT 0
      )
      ''',
      'CREATE INDEX idx_products_category ON products(category_id, name)',
      // Lookups by barcode happen on every scan, so they get their own index.
      'CREATE INDEX idx_products_barcode ON products(barcode)',
      '''
      CREATE TABLE modifier_groups (
        id            INTEGER PRIMARY KEY,
        name          TEXT NOT NULL,
        sequence      INTEGER NOT NULL DEFAULT 0,
        min_selection INTEGER NOT NULL DEFAULT 0,
        max_selection INTEGER NOT NULL DEFAULT 0,
        required      INTEGER NOT NULL DEFAULT 0
      )
      ''',
      '''
      CREATE TABLE modifiers (
        id         INTEGER PRIMARY KEY,
        group_id   INTEGER NOT NULL,
        name       TEXT NOT NULL,
        price      REAL NOT NULL DEFAULT 0,
        price_type TEXT NOT NULL DEFAULT 'fixed',
        sequence   INTEGER NOT NULL DEFAULT 0,
        product_id INTEGER,
        FOREIGN KEY (group_id) REFERENCES modifier_groups(id) ON DELETE CASCADE
      )
      ''',
      'CREATE INDEX idx_modifiers_group ON modifiers(group_id, sequence)',
      // Which groups apply to which product. Resolved locally on every tap, so it
      // must be an indexed join and not a scan.
      '''
      CREATE TABLE product_modifier_groups (
        product_id INTEGER NOT NULL,
        group_id   INTEGER NOT NULL,
        PRIMARY KEY (product_id, group_id),
        FOREIGN KEY (group_id) REFERENCES modifier_groups(id) ON DELETE CASCADE
      )
      ''',
      // When the catalogue was last refreshed, so the till can warn that it is
      // selling from stale prices rather than pretend everything is fine.
      '''
      CREATE TABLE catalogue_meta (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
      ''',
    ],

    // v2 -> v3: cashiers, so a shift change works with no network.
    //
    // The PIN is stored only as an Argon2id hash with a per-user salt. Nothing here
    // can be turned back into a PIN, which matters because this table sits on a
    // device that can be stolen.
    [
      '''
      CREATE TABLE users (
        id        TEXT PRIMARY KEY,
        name      TEXT NOT NULL,
        pin_salt  TEXT NOT NULL,
        pin_hash  TEXT NOT NULL,
        role      TEXT NOT NULL DEFAULT 'cashier',
        active    INTEGER NOT NULL DEFAULT 1
      )
      ''',
      'CREATE INDEX idx_users_active ON users(active, name)',
      // The signed device authorisation, cached so an outage cannot lock the till.
      '''
      CREATE TABLE device_enrolment (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
      ''',
    ],
  ];
}
