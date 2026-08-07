# Syncing to Odoo

## Decision: go through a backend, not straight to Odoo

**Tills talk to a backend service. The backend holds the one Odoo credential.**

This is forced by the licence constraint, and the evidence is in the code we already
run:

| Route | What it does | Verdict |
|---|---|---|
| `jouma/flutter_api` | `auth_controller.py:38,102` call `request.session.authenticate(db, credential)`, authenticating each caller as a real `res.users` | **Unusable.** Every cashier becomes an Odoo user, so every cashier is a licence |
| `Dishflow-pos/pos_backend` | `config.py:14-15` holds a single `odoo_username`/`odoo_password`; tills authenticate to the backend with JWT (`app/core/auth.py`) | **Correct shape.** One Odoo licence total |

Three further reasons beyond licensing:

1. **The Odoo password never reaches a till.** One admin credential spread across
   tablets in a shop is the whole business sitting on stealable hardware.
2. **One writer to the shared account.** Several tills pushing a week of backlog
   through one login needs serialising somewhere, and that somewhere cannot be the
   tills.
3. **One place to fan out.** Odoo is the accounting record, Firebase the real-time
   layer. The till writes once; the backend distributes. Dual-writing from the device
   produces sales that exist in one and not the other.

## What the till sends

Every order push carries these, and each one exists for a reason that has already
gone wrong somewhere:

| Field | Why |
|---|---|
| `uuid` | Idempotency key. A push can be retried after the server committed but before the acknowledgement was recorded, so the server must treat a repeat as the same sale |
| `created_at` | The moment of sale. Without it a week of offline orders all post on the day the line returned |
| `business_date` | The trading day, with a 04:00 cutover, so a service running past midnight stays on one report |
| `cashier_id` | With one shared login Odoo attributes every order to the same user, so this is the only record of who rang it |
| `device_id` | Which till, for reconciliation and support |

## What the backend must do

### 1. One session per trading day, backdated

A week offline is a week of trading days. Each order goes into the session for its
`business_date`, created if absent with its `start_at` and `stop_at` on that date.

Putting a week of orders into a single open session posts a week of revenue on one
accounting date. Daily sales, Z-reports and the cash-up are then permanently wrong,
and **no client-side change can repair it afterwards**.

```
find or create pos.session where config_id = <till's config>
                            and business_date = <order.business_date>
set date_order = order.created_at   # never "now"
```

Sessions for past days should be opened and closed around the orders they hold, not
left open, or the next day's cash-up inherits them.

### 2. Reject a repeat, do not duplicate it

Look up the order by `uuid` before creating. Return the existing id if found.

`pos_backend/app/services/odoo_sync.py:348` currently creates a `pos.order` with a
generated name and no uuid lookup, so a retry after a partial failure books the sale
twice. It also sends neither `session_id` nor `date_order`, which is both problems
above.

### 3. Distinguish the two failures

The till's outbox depends on this distinction and behaves very differently for each:

- **Transient** (server down, 5xx, timeout, captive portal): the till keeps the sale
  and retries forever. Nothing is lost.
- **Permanent** (validation failure, product deleted, malformed): the till parks that
  one sale, keeps the rest moving, and surfaces it for a human. Return an
  unambiguous permanent error so a single bad order cannot strand a week of takings
  behind it.

Anything ambiguous should be reported as transient. A sale wrongly retried is noise;
a sale wrongly parked is money missing from the books.

### 4. Attribute the cashier

Store `cashier_id` on the order. Odoo's own audit trail will say the shared user did
everything, so the till's audit log, pushed as `audit.push`, is the real record of
who did what. Keep it.

## Message kinds the till queues

| Kind | Key | Notes |
|---|---|---|
| `order.push` | order uuid | The sale. Must be idempotent |
| `audit.push` | `audit-<id>` | Who did what, since Odoo cannot say |
| `device.status` | device id | Heartbeat. Keyed on the device so it replaces rather than accumulating during the outage it describes |

## Catch-up shape after a long outage

A week is roughly 1,400 to 3,500 orders. The till drains continuously rather than one
batch per tick, so the limit is the server. The backend should accept a batch, keep
per-order idempotency, and answer per order rather than failing a whole batch on one
bad member.
