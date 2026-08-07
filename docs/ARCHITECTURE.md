# Architecture

## Why this exists

The Odoo POS is a web page served from Odoo.sh. Measured on Odoo 18, with the
network cut at the browser:

| Situation | Odoo POS |
|---|---|
| Line drops while the tab is open | Keeps selling, orders sync on reconnect |
| Tab closed / reloaded / machine rebooted, still offline | **Dead.** `ERR_INTERNET_DISCONNECTED` |

The cause is not a bug, it is the shape of the thing. Odoo persists **only orders**
to IndexedDB (`DataServiceOptions.databaseTable` lists `pos.order`, `pos.order.line`,
`pos.payment`, lots and custom attribute values). Products, taxes, pricelists and
partners are never written to disk, and the service worker in `web` caches a single
placeholder page. So even with the HTML cached, a cold start has an empty catalogue.

An **installed** app removes the constraint entirely: the binary and the catalogue
are already on the device. That is the whole reason this repo exists.

## The rule everything else follows

> **The till owns its data. The server is a destination, not a dependency.**

No screen may block on the network. No sale may require a round trip. Anything that
cannot be answered from local storage is either cached ahead of time or not on the
critical path.

## Data model

Every record the till creates carries a **client-generated UUID as its identity**,
assigned at creation, never reassigned by the server. This is what makes replay safe:
the same order pushed twice is the same order, so sync needs no merge logic and no
conflict resolution.

Server ids, when they come back, are stored alongside as a *reference*, never as the
identity.

## Sync is a queue, not a merge

Writes go to an append-only **outbox**. The sync worker drains it in order, with
retry and backoff. Rules:

- The till never waits for the outbox. Selling and syncing are independent.
- The server never edits a till's sales. One-way ownership removes the entire class
  of conflict bugs.
- Draining is idempotent because of the client UUID, so a half-finished drain is safe
  to repeat.
- Nothing is deleted from the outbox until the server has acknowledged it.

## Storage

SQLite, encrypted at rest (SQLCipher). Versioned migrations, tested, run on launch.

A migration failure on a till holding unsynced sales is the worst bug this app can
have, so migrations are additive first and destructive only after a release that
proves the new column is populated.

## Auth

Offline-first auth, in two layers:

1. **Device enrolment.** When online, the server issues a signed, time-boxed device
   token. It is cached and renewed silently whenever the line is up.
2. **Cashier PIN.** Verified locally against an Argon2id hash cached on the device,
   so a shift change works with no network.

The token's grace period must be **longer than the worst realistic outage**. A
licence or auth check that phones home to authorise a sale rebuilds the exact problem
this app exists to solve.

Every offline login is written to the audit log and synced later.

## Printing

ESC/POS text straight to the printer. Not an image.

Odoo rasterises the receipt (`html-to-image`), which costs seconds per print, mostly
spent inlining ~4 MB of base64 font data into the clone on every single receipt.
Sending text avoids all of it and prints in the time the printer takes.

## Updates

- Never update while unsynced orders exist, and never mid-shift. Gate it in code.
- The sync API keeps N-1 (ideally N-2) compatibility, because an offline till can be
  several versions behind.
- Staged rollout: one branch, then the rest.

## Backend

Odoo remains the system of record for accounting and inventory. The till talks to it
through an API boundary, never by pretending to be an Odoo client. Keep pricing
rules, promotions and reporting server-authoritative; the till holds what it needs to
sell and nothing more.
