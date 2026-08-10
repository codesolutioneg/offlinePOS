# Syncing to Odoo

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
| `lines[].product_id`, `quantity`, `unit_price` | The sale itself; a whole-order discount is folded into each line's `unit_price` before sending |
| `lines[].modifiers[].product_id` | Each modifier backed by a product becomes its own order line, so it moves stock and invoices exactly as on-site |

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

## Catch-up after a long outage

A week is roughly 1,400 to 3,500 orders. The till drains continuously rather than one
batch per tick, so the limit is the server. Idempotency per `uuid` makes the whole
catch-up safe to interrupt and resume at any point.
