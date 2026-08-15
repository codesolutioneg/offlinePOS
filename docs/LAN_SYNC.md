# The shop network

How the devices in one shop share operational state: two tills, a kitchen screen, a
floor plan that reads the same on all of them.

This is **device-to-device on the shop LAN and needs nothing from Odoo**. No cloud, no
broker, no server round trip, no new endpoint on the sync module. It keeps working with
the internet cut, which is the point: the state a service depends on minute to minute
must not sit behind the one link that fails.

It is also **not encryption**. Events travel as plain JSON over plain HTTP, so pairing
is an authentication boundary, not secrecy. Anything that can capture traffic on the
switch can read a page it caught. See docs/SECURITY.md for what that does and does not
buy.

Nothing here is ever on a selling path. A sale is a local write; the fabric appends an
event in the same transaction and hands it over afterwards, so a dead peer, a slow peer
or a switch that vanished costs a log line on a background timer.

## What is shared, and what is not

Three event kinds, because these are what a shop notices the moment it runs a second
device. Nothing invents a record type: every event applies through a store that already
exists, and every screen keeps reading the local database.

| Kind | Carries | Why it is its own kind |
|---|---|---|
| `order.upsert` | A held or paid order, whole payload, or a discarded tab flagged `deleted` | Drafts are deliberately absent. An order being rung changes on every tap and no other device has a use for it |
| `kitchen.status` | One ticket's new board status | So a kitchen screen can advance a ticket it does not own without claiming authorship of somebody else's sale |
| `table.upsert` | A floor element added, moved, resized or deleted | Table *occupancy* is not a kind: it is derived from the parked orders, which already replicate, so a second source of truth for "table 5 is busy" cannot disagree with the bill on it |
| `product.availability` | One product marked sold out or put back on | Running out is a fact about the shop, not about a sale. The till nobody shouted at has to refuse the same item |
| `order.claim` | A parked tab changing hands, sent by the till giving it up | The one ownership change in the fabric. Only the current owner sends it, and it sends it as part of letting go, so the tab still has exactly one owner at every instant |
| `reservation.upsert` | A table booked ahead, changed or called off | Shared for the same reason the floor plan is: a booking taken at the counter has to reach the handheld, or two people promise one table |

Replication makes a device show more, never own more. `OrderStore` splits its reads and
the split is load-bearing:

- **This till only:** drafts, held tabs to recall, paid-awaiting-sync, recent sales for
  history and reports. A bill is settled on the till it was opened on, and the sweep
  that feeds the outbox is scoped the same way, so a sale rung elsewhere can never be
  recalled, reported or booked from here.
- **Shop-wide:** kitchen tickets and every parked order, so the floor plan colours a
  table busy on the other till and a dedicated board is not permanently blank.

The applier holds no outbox and no sender at all, which is what makes double-booking
structurally impossible rather than merely avoided.

## Discovery: a broadcast beacon

UDP broadcast on `LAN_PORT + 1` (45334 by default), every 10 seconds, carrying
`device_id`, `name`, `port` and `schema` and nothing else. It goes to every device on
the subnet, so nothing about a sale or a customer belongs in it.

Broadcast rather than mDNS or a written-down address list: a shop plugs in a second till
without anyone typing an address, and DHCP leases move, so anything recorded at
installation goes stale. A peer's identity is its device id, never its address, so a
device that comes back on a new lease is the same peer and is not replayed from zero.

The socket binds to every interface (a broadcast datagram is not addressed to this
device, so a socket bound to the LAN address alone would never be handed one) and
targets `x.x.x.255` per subnet, assuming a /24 the way the printer sweep already does.
A peer goes stale after 2 minutes without a beacon, and then its events simply stop
being pulled. An empty peer list is the ordinary single-till case and changes nothing
about selling.

## The two endpoints

Served over HTTP on `LAN_PORT` (45333 by default), bound to the device's first LAN
address rather than to every interface, so this is a shop-floor service and not
something reachable from wherever else the device is plugged in. A device with no LAN
address opens no socket, and a port already in use is logged and the till sells exactly
as it did before.

**`GET /lan/events?since=<seq>&schema=<n>`**

```json
{ "device_id": "...", "schema": 15, "high_seq": 812, "events": [ ... ] }
```

**`POST /lan/notify`**

```json
{ "device_id": "...", "schema": 15, "events": [ { "kind": "order.upsert",
  "origin": "...", "seq": 812, "uuid": "...", "payload": { }, "at": "..." } ] }
```

answered with `{"applied": <count>}`.

**`POST /lan/claim`**

```json
{ "device_id": "...", "schema": 15, "order_uuid": "...", "cashier": "..." }
```

answered with `{"device_id": "...", "schema": 15, "order": { }}`, or `409` and a
reason. The one request in the fabric that asks rather than tells, because it is the
one thing that needs an answer: a tab moves only when the till that owns it gives it
up, and it gives it up inside the same handler that agrees, so there is no instant
where two devices could each settle the bill. A till that does not answer therefore
keeps its tab. That refusal is the feature: taking a tab from a device that could not
be asked is how one bill gets settled twice. Both sides record the handover in the
audit trail (`order.claim.granted`, `order.claim.taken`, `order.claim.refused`), and
the owner announces it to everyone else as an `order.claim` event so a third device
sends the waiter to the right till. Off by default per device (**Shop network, Let
another device take over a tab**) and manager-gated on the device asking.

Pulling is the truth and pushing is only latency. Each device asks each peer for
everything after the cursor it holds on disk, so a device that was off, asleep or on the
wrong side of a dead switch catches up completely the moment it can talk again. A notify
hands a change over immediately so a second till is current in milliseconds; a notify
that fails is forgotten, because the pull behind it delivers the same event anyway.

Pacing: one pass every 5 seconds, up to 200 events a page, up to 10 pages per peer per
pass so one very stale peer cannot own the pass, and a 3 second timeout on everything.

## The log, the cursors and the deferral rule

Three tables, added in schema v15:

- `lan_events`: append-only, **locally originated events only**. A till serves its own
  log and nothing else, so an event has exactly one origin and travels exactly one hop.
  That is what stops two tills echoing an order back and forth.
- `lan_cursors`: how far this device has read each peer, keyed by the peer's device id.
  Never moves backwards.
- `lan_clocks`: when each record was last written and by which device. The input to the
  conflict rule, stamped for local changes as well as replicated ones.

`high_seq` is not always the seq of the last event in a page: a peer may hold events
this build cannot read, and the cursor still has to move past them or the same page is
fetched forever. One unreadable event is logged and skipped rather than spoiling the
page.

**Deferral.** A `kitchen.status` for an order this device has never seen is *deferred*,
not refused: the owning till's upsert is still coming. The peer's cursor is held just
below that event so the next pass fetches it again, which is safe because everything
before it is an upsert keyed on a uuid and re-reading it changes nothing. This is
bounded by `LanApplier.waitPasses` (10) passes, after which the abandonment is recorded
in the audit trail and the cursor moves on, because a bump for an order the owning till
discarded would otherwise stop that peer's catch-up for good. The waiting state is in
memory only: a restart is welcome to try again, and retrying is cheaper than a schema
change to remember a bump that may never be applicable.

## The conflict rule

**Last write wins per record**, and when two devices stamp the very same instant the
higher device id wins. The tiebreak is arbitrary, but it is the same arbitrary answer on
every device, which is the property that matters.

Two rules sit on top of it:

- **Order state only moves forward** (draft, held, paid, synced). A paid order never
  loses to a held one whatever the clocks say: money taken is not something a later edit
  can undo.
- **A delete only removes an unpaid order**, so a replicated discard can never quietly
  erase a sale.

The record is written before its clock is stamped, deliberately. Interrupted between the
two, the event is re-applied on the next pull, and every kind is an upsert keyed on a
uuid; the other order would mark a record up to date that was never written.

## Pairing and the auth contract

The devices in one shop hold a shared **shop key**: 32 random bytes, url-safe so it
survives being pasted into a field or read down a phone. The key never goes on the wire.

Every request carries a stamp in the `x-lan-auth` header:

```
x-lan-auth: <unix-millis>.<hex HMAC-SHA256>
```

signed over exactly this request, newline separated:

```
<method>\n<path>\n<canonical query>\n<unix-millis>\n<body>
```

The canonical query is the query parameters sorted by name and joined as
`name=value&name=value`, so the order a map happened to be built in cannot break a
signature. Because the stamp covers the method, path and body, it cannot be lifted off a
pull and reused on a notify. Digests are compared in constant time.

Auth is the **first** gate: it runs before the body is parsed and before the schema is
checked, so an unpaired device gets no say in what a till spends its time decoding. A
refusal is `401` with the reason, and the reason is recorded in the audit trail so a
support call can tell the three cases apart:

| Reason | Meaning |
|---|---|
| `missing` | No stamp at all: something on the subnet that is not a paired device |
| `wrongKey` | A valid-looking stamp that does not verify: the device is paired to another shop |
| `staleClock` | Stamped further out than `LanCredential.clockTolerance` (15 minutes), so one of the two clocks is wrong |

Replay is not defended against and does not need to be: a repeated pull re-reads, and a
repeated notify re-applies events that are idempotent on their uuid.

The key is generated on the device the first time sharing is switched on, held in the
encrypted settings store, and copied to the other devices from the shop network screen
(**Copy**, then paste and **Save** on the next device). **New key** rotates it and
unpairs every other device until each is given the new one, which is the right move
after a key has been handed to someone who should not have it and the wrong move by
accident, so it asks first.

## Schema-version compatibility

Both ends state `Schema.version`, in the beacon and in every request. Events are only
exchanged between devices on the same version:

- A beacon on another version is refused, logged once per peer, and listed under
  **Turned away** on the shop network screen, so a half-finished rollout is visible on
  the device rather than only in a log.
- A request on another version is answered `409` with this device's version.

Tolerating a mismatch would mean writing a record shaped for a database this device does
not have, and a half-understood order is worse than a missing one. During a staged
rollout, the devices that share are the ones already upgraded; the rest keep selling and
join when they are upgraded.

## How to enable it

On the device: **Settings, Shop network**. The switch shares open tabs, kitchen tickets
and the floor plan; below it are the device's name (what the other devices show it as)
and the shop key. Changes take effect when the device next starts, because the node is
assembled at startup.

The build only supplies the default, so a shop that adds a second till flips a setting
instead of waiting for a new binary:

| Define | Effect |
|---|---|
| `LAN_FABRIC=true` | Sharing on by default |
| `KDS_MODE=true` | This device is a kitchen screen, which implies sharing by default |
| `LAN_PORT=<n>` | Serve on `n`, announce on `n + 1` |

With sharing off, nothing is built: no event is appended, no socket is opened, and the
till behaves exactly as it did before the fabric existed.

## Kitchen screens

`KDS_MODE=true` makes a device a kitchen board and nothing else. It boots straight into
the board with no sign-in and no open shift, because a cook takes no money and a board
bolted to a wall behind a cashier's PIN is a board nobody uses. Every ticket on it
arrived over the fabric, and a bump leaves as a `kitchen.status` event rather than a
claim on somebody else's sale, so the device can neither ring up, report nor push
anything. Its one door to the shop network screen is on the board's app bar, ungated:
there is no roster on this device, so a manager PIN would be a lock with no key, and
what is behind it is a device id, a name and who else is on the LAN.

The printed ESC/POS kitchen ticket is untouched by any of this and remains the answer
for a kitchen with no screen.

## When it goes wrong

Every refusal, dead peer and failed announce lands in the audit trail under `system`,
where support already looks: `lan.peer.joined`, `lan.peer.refused`, `lan.event.refused`,
`lan.event.abandoned`, `lan.pull.failed`, `lan.notify.failed`, `lan.host.unavailable`,
`lan.beacon.unavailable`, `lan.publish.failed`. A shop that quietly stopped replicating
has to be findable after the fact.

The shop network screen answers the two questions a support call starts with, both as
facts about right now rather than a green dot: what this device is (device id, the
address and port it is answering on, data version, when the last catch-up ran, the last
problem) and who else it can see (each peer's last-seen age and the seq this device has
read it to, plus a **Catch up now** button and the turned-away list).

One thing deliberately never fails quietly the other way: if a change commits but its
event cannot be written, the change stands and the failure is audited. Losing money
because a replication table misbehaved would be a far worse bug than two devices
disagreeing about a tab.
