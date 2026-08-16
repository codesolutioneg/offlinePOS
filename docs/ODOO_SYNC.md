# Syncing to Odoo

## The server contract is fixed

The till uses **one write entry point, `sale.order.create_from_offline_pos`, plus reads
of models that already exist in the customer's database** through the generic `call_kw`
path (`pos.category`, `product.product`, `account.tax`, `pos.payment.method`,
`res.partner`, and jouma's own modifier models). That is the whole contract, and **no new
endpoints are added**: every feature on this till is built to work against those calls or
to stay on the device. A capability that would need a new server endpoint is a decision to
take deliberately, with the module change and its deployment priced in, not something
that appears because a screen wanted it.

State that is shared between the devices in one shop does not go through Odoo at all. It
is device-to-device on the shop LAN; see docs/LAN_SYNC.md.

## What we book, and why it is a sale.order

An offline sale is booked as the **full on-site chain**, not a bare `pos.order`:

```
sale.order  ->  action_confirm       (sales analysis)
            ->  delivery validated    (stock.move / inventory)
            ->  customer invoice       (account.move / financials, posted)
            ->  payment registered     (account.payment, invoice paid)
```

The reason is the customer's existing reports. They read `sale.order` (sales
analysis), `stock.move` (inventory valuation) and `account.move` (financials); a
bare `pos.order` feeds none of them. Matching jouma's own structure means an offline
sale shows up in every report and module exactly like a sale rung on the spot, so the
customer sees no gap and loses no feature.

Every record is dated to when the sale was actually **rung**, not when it synced.
Backdating the valuation date goes through jouma's `stock_accounting_date_adjustment`
module, so a week of offline orders lands on the right accounting days instead of all
posting on the day the line came back.

This lives in the `pos_offline_sync` Odoo module: `sale.order.create_from_offline_pos(payloads)`.

## When the till syncs: at shift close, not per order

Orders are **held on the till and pushed to Odoo as one batch when the shift is
closed**, not one-by-one as they are rung. The shop runs on a single shared Odoo
login, and booking the day's sales in one settlement at close is how the books are
meant to be written (it mirrors jouma's rescue-session-at-one-accounting-close
model). A manual **Sync now** in Support pushes the batch early if needed.

What runs in the background is read-only and books nothing:

- A **connectivity probe** every ~20s (an unauthenticated `version_info` call) keeps
  the **online/offline badge** on the sell screen honest.
- A **catalogue refresh** when prices are stale.

The periodic loop never starts an order push of its own. Selling is always available
offline; the badge only tells the cashier whether the close-of-shift push will land now
or wait.

### Finishing a close that failed

The one exception, and it is a narrow one: a batch push that already ran and did not get
everything out is **armed**, and the loop then makes bounded attempts to finish *that*
batch. The day's takings are not something to leave waiting on somebody remembering to
tap Sync now the next morning. The read-only pass itself stays read-only; the retry is a
separate step beside it.

| Bound | Value | Why |
|---|---|---|
| What arms it | A batch push (shift close or manual sync) that ends with sales still queued | Only sales. A push that failed on the catalogue read with nothing owed to the server has nothing to deliver, and the periodic refresh re-reads the catalogue anyway |
| Retry window | 12 hours from the **first** failure, never extended by a later one | Wide enough to sit through an overnight outage and deliver before the shop opens, bounded so a till pointed at a dead server stops pretending a retry is still coming |
| Pacing floor | One attempt per 5 minutes | The loop ticks every 20s, and a drain against a dead server costs a socket timeout plus a burnt attempt on every queued entry |
| Offline | Skipped, no socket opened | The probe has just run on this same pass, so an offline till costs nothing here |
| Already pushing | Skipped | A manual sync or a shift close in flight owns the queue; a second attempt would only fight it for the same entries |
| Work per attempt | 10 batches | A long backlog is worked through over several attempts rather than one long run behind a cashier who is mid-sale |

It disarms the moment the queue is empty, whether this retry emptied it or a manual sync
did. When the window closes with sales still queued it disarms too, and records that it
gave up rather than leaving a till that looks like it is still trying. Support sees the
armed state, the reason, the attempt count and the time of the last attempt.

**The armed state is in memory only.** A restart forgets it, and the queued sales are
then pushed by the next shift close or a manual Sync now. Nothing is lost either way:
the sales are durable and the server is idempotent on the uuid. Persisting the armed
flag would buy a retry across restarts and cost a schema column, which is a trade worth
making only if a till is seen restarting inside its own outage.

## Recovering from an outage

Every order is written to the encrypted local database the instant it is paid, so
nothing depends on the network. If the till is **offline at shift close**, the batch
push fails cleanly, the orders stay queued, and the cashier is told they are safe and
will sync when the connection returns (or from Support > Sync now). Because every push
carries the client `uuid` and the server is idempotent on it, a batch that was
interrupted half-way is simply pushed again: already-booked sales come back as
`duplicate` and are skipped, the rest book. No sale is lost and none is double-booked.

## The one credential

The till authenticates to Odoo as a **single shared integration user** (`offlinepos_sync`
on staging). One Odoo licence total, never one per cashier. The password is a build/
config value, not baked into the binary. Because that shared user rings everything,
the client `cashier_id` / `device_id` on each order is the only record of who and
which till actually made the sale, so both are stored on the `sale.order`.

### Integration-user setup (required, checked up front)

The module refuses to book with a clear message if any of these is missing, rather
than failing deep in the delivery step:

| Requirement | Why |
|---|---|
| Group **Point of Sale / User** | The catalogue pull reads `pos.category` and `pos.payment.method` |
| Group **Sales**, **Invoicing**, **Inventory / User** | Confirm the sale, validate delivery, post and pay the invoice |
| Group **Stock Accounting Date Manager** | Backdating the valuation date is gated behind it |
| An **email address** on the user | Backdated delivery posts an audit note via `message_post`, which requires the author to have an email |

## What the till sends

Every order push carries these, each one for a reason that has gone wrong somewhere:

| Field | Why |
|---|---|
| `uuid` | Idempotency key. A push can be retried after the server committed but before the ack was recorded, so a repeat must return the original sale, not book a second one |
| `created_at` | The moment of sale. Without it a week of offline orders all post on the day the line returned |
| `cashier_id` | With one shared login Odoo attributes every order to the same user; this is the only record of who rang it |
| `device_id` | Which till, for reconciliation and support |
| `config_id` | Which point of sale ("restaurant") the sale belongs to, when the shop has named one. It is the id the module resolves first; without it the server has to match the till by its `device_id` against a point of sale that was set up to expect it, and a till nobody set up is refused |
| `company_id` | Which branch. A branch in jouma is a company: its branch reporting filters `account.move` on `company_id` |
| `warehouse_id` | Which warehouse the stock leaves from |
| `lines[].product_id`, `quantity`, `unit_price` | The sale itself; a whole-order discount and the service charge are both folded into each line's `unit_price` before sending, so the module books what the customer paid without learning a new field, and the service is taxed at each item's own rate. The till keeps the percentage locally to print it as its own line; it is stripped from the payload |
| `lines[].modifiers[].product_id` | Each modifier backed by a product becomes its own order line, so it moves stock and invoices exactly as on-site |

### Where the shop is, and who decides

The branch, the point of sale and the warehouse are typed on the server screen and
kept as three ids in the settings table (no schema change: settings are key-value).
They are **stamped when the sale is pushed, not when it is rung**, so a week of
takings sold before a manager named the shop still books in the right place. An id
left blank does not travel at all: an unset id must never arrive as a zero, which
Odoo would read as a real record.

Only `config_id` is known to change what the server does today: the module resolves
the point of sale from it before falling back to matching `device_id`. `company_id`
and `warehouse_id` ride on the sale for the module to honour; a module that does not
read them books against the point of sale's own company and picking type as before,
so setting them can never make a sale worse, and the day the module reads them the
till already sends them.

## How the module answers

`create_from_offline_pos` returns one status dict per order, so a batch never fails
whole on one bad member:

| status | Meaning | Till behaviour |
|---|---|---|
| `created` | Booked | Ack, mark sent |
| `duplicate` | Same `uuid` already booked (a safe repeat) | Ack, mark sent |
| `rejected` | Retrying cannot help (deleted product, locked period) | Park this one, let the rest of the backlog through, surface for a human |

Each order is booked in its own savepoint, so one rejection cannot poison the
transaction and discard the others.

## The two failures the till distinguishes

- **Transient** (server down, 5xx, timeout, captive portal): keep the sale and retry
  forever. Nothing is lost. Anything ambiguous is treated as transient.
- **Permanent** (`status: rejected`, or an Odoo error): park that one sale, keep the
  rest moving. A sale wrongly retried is noise; a sale wrongly parked is money missing
  from the books, so the bar for "permanent" is high.

## Message kinds the till queues

| Kind | Key | Notes |
|---|---|---|
| `order.push` | order uuid | The sale. Idempotent on the uuid |
| `audit.push` | `audit-<id>` | Who did what, since Odoo's trail only shows the shared user |
| `device.status` | device id | Heartbeat. Keyed on the device so it replaces rather than accumulating during the outage it describes |

`order.push` is the only kind with a real sender. `audit.push` and `device.status` are
registered as local acks: the client side is complete, and a sink for them would be a new
server endpoint, which per the contract above is not being built. The local audit log
stays the record of who did what.

## The shift stays on the till

There is **no shift endpoint, deliberately**. The opening float, the drawer movements,
the counted cash and the over/short are read on the till as the X and Z figures (now with
per-tender totals, so a Z read reconciles against the drawer without re-deriving which
methods are cash) and they go nowhere else. Sending them would mean a new server entry
point to book a cash session, and the till builds nothing that requires one.

One thing was added ahead of that decision: a shift now carries a `uuid` of its own
(schema v14) alongside its till-local id. Nothing reads it. It exists so that **if** the
decision is ever revisited, a shift is already replay-safe on a key and the change is a
sender plus a module entry point rather than a migration in the same release.

## Catch-up after a long outage

A week is roughly 1,400 to 3,500 orders. They push as one batch at the next shift
close (or a manual Sync now), draining until the queue is empty, so the limit is the
server. Idempotency per `uuid` makes the whole catch-up safe to interrupt and resume
at any point.
