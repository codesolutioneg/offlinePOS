/// Versioned schema.
///
/// Migrations are additive first. A till can be holding unsynced sales when it
/// updates, so a destructive migration is only acceptable one release after the
/// replacement column is proven to be populated.
class Schema {
  static const int version = 22;

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

    // v8 -> v9: the floor plan and on-device configuration.
    [
      // Tables the shop laid out, grouped into sections and positioned on a floor
      // so a dine-in order can be started or recalled by tapping its table. Held
      // locally like everything else, so the floor works with no network.
      '''
      CREATE TABLE pos_tables (
        id       TEXT PRIMARY KEY,
        section  TEXT NOT NULL DEFAULT 'Main',
        name     TEXT NOT NULL,
        seats    INTEGER NOT NULL DEFAULT 4,
        pos_x    REAL NOT NULL DEFAULT 0,
        pos_y    REAL NOT NULL DEFAULT 0,
        sequence INTEGER NOT NULL DEFAULT 0
      )
      ''',
      'CREATE INDEX idx_pos_tables_section ON pos_tables(section, sequence)',
      // A general on-device settings bag: shop name and tax id for the receipt,
      // receipt toggles, category colours, quick comments, discount reasons. One
      // key-value table rather than a column per setting, so a new toggle is a
      // write and not a migration.
      '''
      CREATE TABLE app_settings (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
      ''',
    ],

    // v9 -> v10: customers created on the till.
    [
      // Walk-in / delivery customers a cashier adds on the device, kept separate
      // from the read-only partners pulled from Odoo. id is a local uuid; a synced
      // Odoo partner id is stored when one is known, so a later sync can link them.
      '''
      CREATE TABLE local_customers (
        id         TEXT PRIMARY KEY,
        name       TEXT NOT NULL,
        phone      TEXT,
        address    TEXT,
        partner_id INTEGER,
        created_at TEXT NOT NULL
      )
      ''',
      'CREATE INDEX idx_local_customers_name ON local_customers(name)',
    ],

    // v10 -> v11: staff attendance (clock in/out), separate from the cash-drawer
    // shift so several cashiers can be on the clock against one till.
    [
      '''
      CREATE TABLE attendance (
        id        INTEGER PRIMARY KEY AUTOINCREMENT,
        staff_id  TEXT NOT NULL,
        clock_in  TEXT NOT NULL,
        clock_out TEXT
      )
      ''',
      'CREATE INDEX idx_attendance_staff ON attendance(staff_id)',
    ],

    // v11 -> v12: table shape, so the floor editor can draw a table as square,
    // round, or rectangular, and drop a wall/divider (a pos_tables row of its
    // own shape) to mark a section split.
    [
      "ALTER TABLE pos_tables ADD COLUMN shape TEXT NOT NULL DEFAULT 'square'",
    ],

    // v12 -> v13: divider geometry, so a wall can be drawn vertical and be
    // enlarged or shrunk. Only dividers read these; a seatable table keeps its
    // fixed tile size and defaults to horizontal.
    [
      'ALTER TABLE pos_tables ADD COLUMN vertical INTEGER NOT NULL DEFAULT 0',
      'ALTER TABLE pos_tables ADD COLUMN span INTEGER NOT NULL DEFAULT 140',
    ],

    // v13 -> v14: a shift's own identity.
    //
    // Nothing reads this yet, which is the point of adding it now: the shift is a
    // till-local artefact today, and giving it an identity before a consumer exists
    // means that if one is ever added the shift is already replay-safe on a key
    // rather than needing a migration in the same release. Existing rows are
    // backfilled from the shift id, which is already unique per till, so an
    // upgraded till has no nulls and no row's identity changes underneath it.
    [
      'ALTER TABLE shifts ADD COLUMN uuid TEXT',
      'UPDATE shifts SET uuid = id WHERE uuid IS NULL',
      'CREATE UNIQUE INDEX idx_shifts_uuid ON shifts(uuid)',
    ],

    // v14 -> v15: the LAN state fabric.
    //
    // A shop with two tills and a kitchen screen has shared state (parked orders,
    // which tables are busy, where a ticket is in the kitchen) that until now lived
    // only on the device that created it. These three tables are what let one till
    // tell another what it did, without a cloud and without a server round trip:
    // everything here is device-to-device on the shop LAN.
    [
      // Only events this device originated, so the origin is implicit and a
      // replicated event can never be re-served to the till it came from. That is
      // what stops two tills echoing one order back and forth forever.
      //
      // Append-only: a row is written next to the record it describes and never
      // edited, so a peer that was switched off all morning catches up by asking
      // for everything after the seq it last saw.
      '''
      CREATE TABLE lan_events (
        seq         INTEGER PRIMARY KEY AUTOINCREMENT,
        kind        TEXT NOT NULL,
        record_uuid TEXT NOT NULL,
        payload     TEXT NOT NULL,
        at          TEXT NOT NULL
      )
      ''',
      // How far this till has read each peer's log. Keyed by the peer's device id
      // rather than by its address: a peer that comes back on a different DHCP
      // lease is the same peer and must not be replayed from zero.
      '''
      CREATE TABLE lan_cursors (
        peer_device_id TEXT PRIMARY KEY,
        last_seq       INTEGER NOT NULL DEFAULT 0,
        updated_at     TEXT NOT NULL
      )
      ''',
      // The clock the last-write-wins rule is decided on, per record. Written for
      // local changes as well as replicated ones, so an event that crossed the LAN
      // slowly cannot overwrite a newer change made here in the meantime.
      '''
      CREATE TABLE lan_clocks (
        record_uuid TEXT PRIMARY KEY,
        kind        TEXT NOT NULL,
        at          TEXT NOT NULL,
        origin      TEXT NOT NULL
      )
      ''',
    ],

    // v15 -> v16: modifier groups that answer themselves.
    //
    // A dish with one standard sauce made the cashier confirm a sheet on every tap.
    // These two flags say which group can settle itself and which option it settles
    // on. Both default to off, so a till that upgrades behaves exactly as it did
    // until the catalogue brings the flags down.
    [
      'ALTER TABLE modifier_groups ADD COLUMN auto_add INTEGER NOT NULL DEFAULT 0',
      'ALTER TABLE modifiers ADD COLUMN is_default INTEGER NOT NULL DEFAULT 0',
    ],

    // v16 -> v17: what a delivery shop keeps on the till.
    //
    // Zones price the drive, channels say which app the order arrived through, and
    // drivers are who carries it. Three lists a manager edits and a cashier picks
    // from, all local: none of them is on the wire, and every one of them works
    // with the line down. Empty tables mean the delivery dialog looks exactly as it
    // did before these existed.
    [
      '''
      CREATE TABLE delivery_zones (
        id         TEXT PRIMARY KEY,
        name       TEXT NOT NULL,
        fee        REAL NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      )
      ''',
      '''
      CREATE TABLE delivery_channels (
        id         TEXT PRIMARY KEY,
        name       TEXT NOT NULL,
        partner_id INTEGER,
        created_at TEXT NOT NULL
      )
      ''',
      // A driver who leaves is deactivated rather than deleted: orders they already
      // carried still name them, and a name on a printed slip must stay resolvable.
      '''
      CREATE TABLE drivers (
        id         TEXT PRIMARY KEY,
        name       TEXT NOT NULL,
        phone      TEXT,
        active     INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL
      )
      ''',
    ],
    // v17 -> v18: mail the shop owner is waiting for.
    //
    // The Z report is the one number an owner who is not in the building wants at
    // the end of the night, and a printed ticket in a drawer is not it. Sending is
    // best effort and must never be able to hold up a cash-up, so the message is
    // written here first and delivered afterwards: the same discipline as the
    // order outbox, and for the same reason.
    [
      '''
      CREATE TABLE email_outbox (
        uuid            TEXT PRIMARY KEY,
        recipients      TEXT NOT NULL,
        subject         TEXT NOT NULL,
        body            TEXT NOT NULL,
        queued_at       TEXT NOT NULL,
        attempts        INTEGER NOT NULL DEFAULT 0,
        last_attempt_at TEXT,
        last_error      TEXT,
        sent_at         TEXT
      )
      ''',
      // Queued first, oldest first, so a night's backlog leaves in the order it
      // happened rather than newest-first.
      'CREATE INDEX idx_email_outbox_pending ON email_outbox (sent_at, queued_at)',
    ],
    // v18 -> v19: tables booked ahead.
    //
    // A reservation is not an order and deliberately not stored as one: nothing is
    // sold, nothing is owed, and a booking that never turns up must not leave a
    // draft sale behind. It is keyed on a uuid rather than on a table and a time so
    // it can be moved and replicated like every other shared record, and it carries
    // its own state rather than being deleted when the guests sit down, because
    // "they came" and "they never came" are different facts a shop wants to see.
    [
      '''
      CREATE TABLE reservations (
        uuid        TEXT PRIMARY KEY,
        table_label TEXT,
        name        TEXT NOT NULL,
        phone       TEXT,
        at          TEXT NOT NULL,
        covers      INTEGER NOT NULL DEFAULT 2,
        state       TEXT NOT NULL DEFAULT 'booked',
        note        TEXT,
        updated_at  TEXT NOT NULL
      )
      ''',
      // The floor asks "what is due in the next hour" on every rebuild, which is a
      // read by time, and the book asks for a day at a time.
      'CREATE INDEX idx_reservations_at ON reservations(at)',
    ],
    // v19 -> v20: what a dish costs and what it looks like.
    //
    // Both are optional on the server side, so both keep their empty default on a
    // till whose Odoo will not part with the field: a zero cost reads as "unknown"
    // in the margin reports and no picture leaves the grid tile exactly as it is.
    // The picture is never read by the queries that build the grid, only by the
    // lookup behind the images toggle, so a menu with photos costs a sale nothing.
    [
      'ALTER TABLE products ADD COLUMN cost REAL NOT NULL DEFAULT 0',
      'ALTER TABLE products ADD COLUMN image BLOB',
    ],
    // v20 -> v21: a second factor for the people who approve things.
    //
    // The shared base32 secret of a time-based one-time code, per user. Null for
    // everyone until a manager enrols one, so a till that upgrades asks for exactly
    // what it asked for before. It is a secret, and it lives here because this
    // database is encrypted at rest; it is never sent anywhere, since the codes are
    // derived from the clock and checked on the device.
    [
      'ALTER TABLE users ADD COLUMN totp_secret TEXT',
    ],
    // v21 -> v22: the till owns its own menu.
    //
    // Until now the catalogue was a copy of Odoo's and a pull replaced it whole,
    // which is fine for a shop whose menu is maintained upstream and useless for one
    // that types its own. Two columns turn that around.
    //
    // `source` says who owns the row. 'odoo' means a pull put it there and a pull may
    // replace or delete it; 'local' means somebody on this till created or edited it,
    // and from that moment a pull leaves it alone. Editing a pulled row flips it to
    // 'local', so the rule is one word long: whoever touched it last on the till owns
    // it, and seeding never outranks a person standing at the counter.
    //
    // `odoo_id` is the record a row books against, which stops being the same thing
    // as the row's own id once a manager can create rows. Backfilled from the id for
    // everything already on the device, because everything already on the device came
    // down from a pull.
    [
      'ALTER TABLE products ADD COLUMN odoo_id INTEGER',
      "ALTER TABLE products ADD COLUMN source TEXT NOT NULL DEFAULT 'odoo'",
      // A per-product tile colour, overriding the category's. Null keeps the tile
      // exactly as it is today.
      'ALTER TABLE products ADD COLUMN color INTEGER',
      'UPDATE products SET odoo_id = id',
      // A pull checks every incoming product against the local rows that claim it,
      // so the claim has to be an indexed lookup and not a scan of the menu.
      'CREATE INDEX idx_products_odoo ON products(odoo_id)',
      'ALTER TABLE categories ADD COLUMN odoo_id INTEGER',
      "ALTER TABLE categories ADD COLUMN source TEXT NOT NULL DEFAULT 'odoo'",
      // Categories gain the archive flag products already had, so removing one hides
      // it without orphaning the products filed under it or the sales that name it.
      'ALTER TABLE categories ADD COLUMN active INTEGER NOT NULL DEFAULT 1',
      'UPDATE categories SET odoo_id = id',
      'CREATE INDEX idx_categories_odoo ON categories(odoo_id)',
      // Modifiers are part of the menu, so they carry the same ownership word. A
      // group a manager typed here survives every pull, including the link that
      // attaches it to a product the pull does own.
      "ALTER TABLE modifier_groups ADD COLUMN source TEXT NOT NULL DEFAULT 'odoo'",
      "ALTER TABLE modifiers ADD COLUMN source TEXT NOT NULL DEFAULT 'odoo'",
      "ALTER TABLE product_modifier_groups ADD COLUMN source TEXT NOT NULL DEFAULT 'odoo'",
    ],
  ];
}
