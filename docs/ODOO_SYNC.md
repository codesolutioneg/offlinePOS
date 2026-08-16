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
| `lines[].modifiers[].product_id` | Each modifier backed by a product becomes its own order line, so it moves stock and invoices exactly as on-site. A modifier with no product is priced into its parent's `unit_price` and travels at zero, because the module has no line to create for it. See below |
| `delivery_cost` | The charge for the drive. Not a line: the module prices it into the sale as its own service line, which is why it has to reach the server as its own figure |
| `tip` | What was left for the staff, and the same shape as the delivery charge for the same reason |
| `discount_amount`, `prices_include_discount` | What was taken off, in money, and whether the prices already have it. See below |
| `amount_total` | What the till charged. The module totals the sale itself from the lines it built; this is the figure to hold that against, so a divergence is visible instead of silent |

### The payload has to add up

The module builds the sale from the `lines` it is handed and then settles it from
the `payments` it is handed. A payload where those two disagree is money that
either fails to book or books wrong, and both end the same way: takings missing
from the books. So the arithmetic is stated rather than assumed:

> **what the payload declares as tendered = what its lines come to, plus
> `delivery_cost`, plus `tip`.**

Both sides come out of the payload itself, and the till will not send one that
does not close (`lib/domain/payload_balance.dart`, checked in the sender before
the call). A payload that fails is **parked**, not sent: the sale keeps its
payload, shows on the diagnostics screen and waits for a human, which is the right
end for a sale nobody can book. The tolerance is one piastre, the same bar the
module holds its own total to.

`test/domain/payload_balance_test.dart` walks every combination of delivery
charge, tip, service percentage, whole-order discount, per-line discount,
discount-product mode, split tender and refund, and holds all of them to that one
line. Adding a charge that reaches the payments and not the lines is a red test.

Two things the till had wrong, both the same shape:

- **A priced choice with no product behind it** ("extra spicy", a size upcharge)
  was charged at the counter and declared nowhere. The parent line's `unit_price`
  is the bare dish, modifiers travel as their own lines, and the module skips a
  modifier with no product because it has no product to make a line from. That
  money simply vanished between the two. It is now folded into the parent's
  `unit_price` and the modifier travels at zero, which is what the module's own
  code already assumed was happening.
- **The delivery charge and the tip** are on the payments but not in the lines,
  and that one is correct: the module prices both into the sale it builds, as
  service lines of their own. They are named in the invariant above rather than
  moved into `lines`, because a second representation of the same money is a
  double booking waiting for a module that reads both.

The thing to verify on the jouma side, and it is the one open question here: what
the module does when the products it books the delivery and the tip against are
not configured. If it raises, the sale is refused, the till parks it and a human
sees it, which is fine. If it drops them, the sale books short and only the
`amount_total` mismatch in the log says so. That is a module-side check, not
something the till can see.

### What a line books against when the shop typed the item itself

The till owns its menu: a manager creates items and categories on the device and they
sell with the line down, linked to an Odoo record or not. The contract is unchanged,
so `lines[].product_id` still has to name a real `product.product`. Which one it names
is decided in this order, and stated rather than left to chance:

| The item is | `product_id` carries | Why |
|---|---|---|
| Linked to an Odoo product | that product's id, captured onto the line when the sale was rung | Relinking the item afterwards must not rewrite a sale that is already booked, for the same reason the price is captured |
| Not linked, and the shop named a **stand-in service product** on the server screen | the stand-in's id, with the line's own `name` alongside it | The money lands in the books and the Odoo document still reads as the dish that was sold. Same shape as the discount product, and a **service** product for the same reason |
| Not linked, and no stand-in named | the till's own negative id | Odoo cannot resolve it, the module answers `rejected`, and the till parks that one sale in front of a human. Nothing at the counter is ever blocked and no money is quietly booked against the wrong product. The menu editor warns about this at the point the item is created |

Locally created items and categories are held with **negative ids**, the same trick a
till-local customer uses, so they can never collide with an Odoo id however the
server's sequences move. The negative id never travels except in the third row above,
where its unresolvability is the point.

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

### Why a discount could not be found in Odoo

The money was always right. A staging run proves it: a 25% order discount books an
`amount_untaxed` of exactly the discounted total
(test/staging/staging_discount_test.dart). What was missing is that **nothing in the
payload said a discount had happened**. The percentages are folded into the line
prices and then zeroed on the wire, so Odoo was handed a cheaper item, not a
discounted one: no discount column, no discount line, nothing for a discount report
there to count, and an invoice quoting a price that is not the menu price.

Two things fix that, and they are independent:

1. **The payload states it.** `discount_amount` is the money given away (per-line
   discounts and the whole-order one together, on the same scale as the prices sent),
   and `prices_include_discount` says whether the prices already have it. Stating it
   rather than re-applying it is what makes double-discounting impossible. This
   always travels. It is inert until the module reads it, but it is the datum a
   module needs and it can never be wrong.
2. **The shop names a discount product** (server settings, a **service** product; a
   negative line on a storable one would put stock back). Then the lines go at full
   menu price and the discount travels as one negative line on that product, which is
   how Odoo writes a discount itself and the only way it appears as one without the
   module learning a new field. Nothing else changes: both ways total to the same
   money, and the sale's per-line service charge stays inside the prices.

The trade in option 2, stated plainly: the discount then carries the discount
product's own tax rather than reducing each item's tax in proportion. For a shop on
one VAT rate the tax total is identical; for a menu with mixed rates it is not, which
is why it is opt-in and off until someone chooses it.

Dishflow sends `discount_amount` / `discount_type` / `discount_value` as top-level
fields and lets its own REST addon decide what to do with them. It can do that
because that addon is theirs to change. Ours is the same information without the
assumption: the amount travels, and the shop chooses whether it also becomes a line.

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

## One sales order for the whole batch: the verdict

The ask is that a sync sends the day's sales to Odoo as **one** sales order rather
than one per ticket, on the understanding that Dishflow already works that way and
so no jouma change is needed. Half of that is right, and the half that is wrong is
the half that matters.

**What Dishflow actually does.** It does consolidate, and it is worth reading before
deciding anything:

- It is a per-shop switch, **off by default**
  (`Dishflow-pos/lib/services/odoo_sync_settings_service.dart`, `_consolidatedInvoice
  = false`), and the app warns on the way out when it is off
  (`lib/features/pos/presentation/home_screen.dart`).
- With it on, session close merges every ticket's lines into one list (aggregated by
  product), sums the payments by journal, sums the discounts into one figure, and
  posts a single order with a note naming how many tickets it holds
  (`lib/features/reports/presentation/session_close_screen.dart`).
- It refuses to consolidate unless a **default partner** is configured: one merged
  order can only have one customer.
- **Credit (on-account) sales are pulled out of the merge** and still sent one by
  one, because an unpaid ticket cannot share a settlement with paid ones.
- It goes through **Dishflow's own REST addon** (`POST /api/.../orders/create`), not
  through standard Odoo. That endpoint takes a flat order with `payments[]`,
  `discount_amount`, `delivery_fee`, an order date and a session PDF, and does the
  booking itself.
- The consolidated call **deliberately drops its idempotency key**: the code strips
  `clientOrderRef` and, when the call times out, hunts for the order by matching an
  expected total against the last confirmed orders of that date
  (`_recoverSaleOrderByClientRef`, `findSessionCloseOrderOnOdoo`).

So "Dishflow works the same way" is true about the *behaviour* and not about the
*contract*: it can merge because the endpoint is theirs to shape, and it paid for it
with the one guarantee this till is built on.

**Can we do it against `create_from_offline_pos` as it stands?** Shaping alone: yes,
technically. The method takes a list of payloads and reads each one with `.get()`, so
a single payload holding every ticket's lines and a merged `payments` list would be
accepted and would produce one document. Nothing on the server has to change for the
call to succeed. What it costs is not the call, it is these:

| What breaks | Why |
|---|---|
| **Idempotency** | The `uuid` is the anti-double-booking key and it belongs to the payload. A batch's key can only come from the set of tickets in it, so any re-cut of that set (one sale parked, one added, a drain interrupted half way) is a different key and books the overlap a second time. This is precisely the wall Dishflow hit, and its answer was to stop keying and start guessing by total and date |
| **The trading day** | One order carries one `date_order` and one `business_date`. A batch that spans the 04:00 cutover, or a week of outage, posts on a single day, and every per-day sales report the module preserves goes with it |
| **Who rang it** | `cashier_id` and `device_id` are per ticket, and with one shared Odoo login they are the only record of who sold what. Merged, they are gone |
| **Rejection isolation** | Today a deleted product parks one sale and the rest book. In one merged order the same product raises inside the one savepoint, and the whole day is rejected together |
| **Refunds and tabs** | A credit cannot be a line on somebody else's sale, and an unpaid on-account ticket cannot settle in a merged payment. Dishflow excludes them, so a merged batch is never actually the whole batch |

Payments are the one part that merges cleanly: the module already takes a list of
`{method_id, amount}`, so per-tender totals survive.

**Verdict: shaping the payload is possible, doing it properly needs a module
change.** The shop has asked for it anyway, so the till half is built and the
module half is written out below for whoever changes jouma. Nothing here is turned
on.

Worth weighing first, and worth asking before the module is touched: **the shop may
already have what it is asking for.** The grievance behind "one sales order" is
usually one document in the books per day rather than three hundred. Odoo's own
answer to that is the close, not the write: the module books a batch into a single
rescue session per point of sale, and closing that session posts one accounting
entry for all of it. Ask the shop whether it wants one row in the sales list or one
entry in the books before anybody changes the contract.

### What the till does, and what it refuses to do

A switch on the server settings screen, **off**, with the warning next to it that
it needs the module change first (`merge_batch_one_sale_order` in settings; no
schema change, settings are key-value). Turned on, a batch push (a shift close, a
manual Sync now, the retry that finishes a failed close) folds the queued sales
into one payload instead of sending one each. Everything else about the till is
unchanged: selling still never waits, sales are still durable the instant they are
paid, and the per-sale push is still what happens whenever the merge declines.

The three things Dishflow traded away to get this out of its own endpoint are
kept:

| | Dishflow | Here |
|---|---|---|
| Idempotency | Strips `client_order_ref` on the consolidated call and recovers from a timeout by hunting the last confirmed orders for a matching total | The merged payload's `uuid` **is the shift's uuid**, which is stable across every retry of the same close, and every constituent ticket uuid rides inside it |
| Per-ticket detail | Aggregates the merged lines by product; who rang what is gone | Every line carries `order_uuid`, and every ticket keeps its own header in `orders[]` (without repeating its lines) |
| Arithmetic | Sums delivery and discounts into one figure and lets the addon work it out | The merged payload is held to the same invariant as a single sale, and is not sent if it fails |

It declines to merge, and lets the ordinary per-sale push do it, when: there are
fewer than two sales; a batch spans a change to how the discount is stated; the
merged payload does not add up; there is no shift to key it on; or the queue is
longer than 500 sales (a week of backlog is not one request). **Refunds are always
excluded** and pushed on their own: a credit cannot be a line on somebody else's
sale.

**Recovering a partial failure.** The batch is all or nothing on the till. The
merged payload goes out first, and only once the server has acknowledged it are the
outbox rows marked sent and the sales marked synced. A close that fails anywhere
before that leaves every sale queued exactly as it was, and the next attempt
rebuilds the same payload under the same shift uuid. That repeat is the whole
recovery: it is the only thing standing between a timeout after the server
committed and a night booked twice. If the batch is re-cut in between, because one
sale was parked or a late one joined, the key stays the same and the per-ticket
uuids inside it are what let the server settle the difference instead of booking
the overlap again. The armed retry goes through the merge too, deliberately: left
to the plain drain, the same sales would go out one at a time under their own
uuids and a batch the server had already committed would be booked a second time
as individual sales.

### The module change this needs (patch proposal for jouma)

Hand this to whoever changes `pos_offline_sync`. Until it is deployed the switch
stays off; turned on against today's module the night books as one document with no
per-ticket record and no per-ticket idempotency.

**Method.** `sale.order.create_from_offline_pos(payloads)`, unchanged signature. A
member of `payloads` with `batch: true` is a batch; anything else is a single sale
and behaves exactly as it does today. No new entry point.

**Payload shape.**

```jsonc
{
  "uuid": "<the shift's uuid>",   // the batch's idempotency key
  "batch": true,
  "order_count": 37,
  "created_at": "<the earliest ticket's moment of sale>",
  "business_date": "2026-03-01",  // absent when the batch spans more than one
  "company_id": 3, "config_id": 7, "warehouse_id": 2,
  "delivery_cost": 120.0, "tip": 45.0,
  "discount_amount": 210.0, "prices_include_discount": true,
  "amount_total": 8430.0,
  "lines": [ { "product_id": 41, "quantity": 2, "unit_price": 100.0,
               "modifiers": [], "order_uuid": "<the ticket this line was rung on>" } ],
  "payments": [ { "method_id": 1, "amount": 6100.0, "label": "Cash" } ],
  "orders":  [ { "uuid": "...", "created_at": "...", "business_date": "...",
                 "cashier_id": "...", "device_id": "...", "order_type": "dinein",
                 "table_label": "12", "delivery_cost": 25.0, "tip": 5.0,
                 "amount_total": 235.0, "payments": [ ... ] } ]
}
```

`orders[]` carries every field a single-sale payload carries **except** `lines`:
those are in the batch's own `lines`, each tagged with the `order_uuid` it belongs
to, so nothing is duplicated and nothing is lost.

**What it must do.**

1. **Idempotency on two levels.** Return the existing document for a repeat of the
   batch `uuid`. And before booking, drop any member of `orders[]` whose own uuid
   is already booked, whether by an earlier batch or by a single push. A retry
   after a re-cut is the normal case, not the exception, and per-ticket dedup is
   what makes it safe.
2. **The ids.** `company_id` is the branch the document belongs to, `config_id` the
   point of sale it books through, `warehouse_id` where the stock leaves from.
   They arrive only when the shop set them; an id that is not there means Odoo
   decides as it does today.
3. **Refuse per ticket, not per batch.** A line whose product was deleted must
   reject the ticket it belongs to and let the rest book, the way a savepoint per
   payload does today. A batch that rejects whole is a night parked over one dish.
4. **Keep who rang what.** `offline_cashier_id`, `offline_device_id`, `order_type`,
   the table and the trading day are per ticket. With one shared Odoo login they
   are the only record there is, so they have to land somewhere per ticket rather
   than being flattened onto the document.
5. **Total and settle the same way.** The document totals from `lines` plus the
   delivery and tip service lines it prices from `delivery_cost` and `tip`, and
   settles from `payments`. `amount_total` is the till's own figure to check
   against.
6. **Answer per batch.** One status dict for the batch `uuid`
   (`created`/`duplicate`/`rejected`), which is what the till reads today: it marks
   every constituent sale synced on a `created` or a `duplicate` and leaves the
   whole batch queued otherwise. Carrying the per-ticket statuses inside that dict
   as well costs the module nothing and is what would let a later till release mark
   exactly what booked when a batch only partly did.

## Catch-up after a long outage

A week is roughly 1,400 to 3,500 orders. They push as one batch at the next shift
close (or a manual Sync now), draining until the queue is empty, so the limit is the
server. Idempotency per `uuid` makes the whole catch-up safe to interrupt and resume
at any point.
