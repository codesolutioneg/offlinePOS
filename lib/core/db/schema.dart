/// Versioned schema.
///
/// Migrations are additive first. A till can be holding unsynced sales when it
/// updates, so a destructive migration is only acceptable one release after the
/// replacement column is proven to be populated.
class Schema {
  static const int version = 8;

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

    // v3 -> v4: dead-lettering.
    //
    // A permanently rejected entry used to stop the queue behind it, which after a
    // long outage means one bad order strands a week of takings. Such an entry is
    // now parked here and the drain continues; parked entries are surfaced loudly
    // rather than dropped, because each one is money that did not reach the books.
    [
      'ALTER TABLE outbox ADD COLUMN dead_at TEXT',
      'ALTER TABLE outbox ADD COLUMN dead_reason TEXT',
      'CREATE INDEX idx_outbox_dead ON outbox(dead_at)',
    ],

    // v4 -> v5: printers, and the help a cashier has switched off.
    [
      // Printers are remembered by name, never by address. The shop runs mesh wifi
      // and DHCP leases drift, so the address written down at installation goes
      // stale and the kitchen quietly stops getting tickets. The name is what a
      // receipt is routed by; host is only the last address that answered, and
      // identity is what the printer called itself, so a rescan can tell the
      // kitchen printer from the bar one.
      '''
      CREATE TABLE printers (
        name         TEXT PRIMARY KEY,
        host         TEXT,
        port         INTEGER NOT NULL DEFAULT 9100,
        identity     TEXT,
        last_seen_at TEXT
      )
      ''',
      // Keyed by wizard as well as by cashier: a till is shared, so the closer
      // switching off the sale walkthrough must not take it away from the starter,
      // and a wizard added in a later release must still show once to someone who
      // dismissed everything that existed before it.
      //
      // No foreign key to users(id) on purpose. A dismissal is not worth failing an
      // insert over when the roster sync has not landed yet, and a row left behind
      // by a roster replace costs the cashier one more sight of the help.
      '''
      CREATE TABLE wizard_dismissals (
        wizard_id    TEXT NOT NULL,
        cashier_id   TEXT NOT NULL,
        dismissed_at TEXT NOT NULL,
        PRIMARY KEY (wizard_id, cashier_id)
      )
      ''',
    ],

    // v5 -> v6: receipts and lockouts that outlive the process.
    [
      // Held receipts used to live in a list in memory, so a printer that was off
      // during a rush lost every one of them the moment the app closed, which on a
      // till is nightly. The sale was always safe on disk; this is what makes the
      // paper side as recoverable as it was always described as being.
      //
      // Keyed by printer name rather than by address, for the same reason the
      // printers table is: the job belongs to 'receipt', not to a lease that moved.
      '''
      CREATE TABLE print_jobs (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        printer    TEXT NOT NULL,
        bytes      BLOB NOT NULL,
        reference  TEXT,
        created_at TEXT NOT NULL,
        attempts   INTEGER NOT NULL DEFAULT 0,
        last_error TEXT
      )
      ''',
      'CREATE INDEX idx_print_jobs_queue ON print_jobs(printer, id)',

      // An attempt limit held in memory is not an attempt limit. Four wrong PINs,
      // force-quit, four more, and a 4-digit PIN is ten thousand tries from open.
      // docs/SECURITY.md calls this out by name.
      '''
      CREATE TABLE auth_attempts (
        cashier_id   TEXT PRIMARY KEY,
        failures     INTEGER NOT NULL DEFAULT 0,
        locked_until TEXT
      )
      ''',
    ],

    // v6 -> v7: the Odoo endpoint a till syncs to.
    //
    // Set at runtime on the device, not compiled in. url, db and login are not
    // secrets. The password is stored here for a single-operator local test only;
    // a fleet must not keep a shared credential on every till, which is why the
    // real deployment authenticates to a backend that holds the one Odoo login.
    // Stated in docs/SECURITY.md as such.
    [
      '''
      CREATE TABLE odoo_endpoint (
        id       INTEGER PRIMARY KEY CHECK (id = 1),
        base_url TEXT NOT NULL,
        db       TEXT NOT NULL,
        login    TEXT NOT NULL,
        password TEXT,
        updated_at TEXT NOT NULL
      )
      ''',
    ],
    // v7 -> v8
    [
      '''
      CREATE TABLE shifts (
        id              TEXT PRIMARY KEY,
        opened_at       TEXT NOT NULL,
        closed_at       TEXT,
        opening_float   REAL NOT NULL,
        cashier_id      TEXT NOT NULL,
        movements       TEXT NOT NULL DEFAULT '[]',
        closing_counted REAL
      )
      ''',
    ],
  ];
}
