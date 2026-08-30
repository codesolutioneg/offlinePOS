# Testing notes from build 1.0.64, and what was decided

The shop owner tested build 1.0.64 (Phase 1 plus Phase 2 wave 1) and came back with the
notes below. Recorded here verbatim in intent, with the decision taken on each, because
three of them reverse choices made earlier in the project and the reasoning matters more
than the change.

Note when reading: 1.0.64 predates Phase 2 wave 2 and all of Phase 3, so some notes were
already answered by work that had landed on main but was not in that build.

## The notes, and the decision on each

| # | Note | Decision |
|---|---|---|
| 1 | Table sections belong at the side, not across the top | Do it |
| 2 | A TO GO order type that can be seated at a table: semi-takeaway, still in the restaurant | New order type, table OPTIONAL, tagged on receipt and kitchen ticket, own tax and service rules |
| 3 | Enable and disable the delivery and to-go options | Shop-level availability setting, composed with the per-role restriction that already exists |
| 4 | The payment slip is not easy or nice to use | Redesign the payment sheet, taking what is better from Dishflow's dialogs |
| 5 | Split by guest sits in another menu; everything about payment belongs in the payment menu | Move the payment-related splits into the sheet; leave move/merge where they are |
| 6 | The receipt prints the table but not the section | Print section and table |
| 7 | Categories and items should be created in the UI and linked to Odoo items | REVERSAL: the till owns the menu; the Odoo pull becomes a source to link from, filtered by restaurant id where possible |
| 8 | Payment methods should come from Odoo | Already pulled from pos.payment.method; find what the owner actually saw and make it obvious, including the empty state |
| 9 | Branch id, restaurant id and warehouse id must be settable | Settings that ride on every booked sale |
| 10 | Sync should send one sales order carrying those ids, not order by order | INVESTIGATE FIRST, see below |
| 11 | A partial, split or by-item payment must print its own detail slip | Do it, through the existing spooled printer |
| 12 | Discounts are not reflected in Odoo | Fix the payload; compare against how Dishflow sends them |
| 13 | Arabic does not print on the receipt | Real failure of shipped work, see below |
| 14 | Modifiers cannot be chosen while ordering, and nothing marks which items have them | Manager-created modifiers, shown when ringing, with a symbol on the tile |
| 15 | A table with a held order must reopen that order | Investigate: the takeover path and guest prompt may have changed it |
| 16 | No ordering at all until a shift is open | Hard gate, with reprint and support still reachable |
| 17 | No closing the shift while money is wrong or orders are open or held, not a warning | Hard block, with the reason visible on screen |
| 18 | Reports need an open-shift filter | Add it beside Today / Yesterday / 7 days |
| 19 | Any report should export to Excel or PDF with a header | Per-report export; the `excel` package is allowed for this |

## The three that needed the owner's decision

**Who owns the menu (7).** Until now Odoo was the master and the till held a read-only
copy, which is why there is no product editor. The owner wants the menu created on the
till and linked to Odoo items, filtered by restaurant id. That is a real reversal, so the
pulled catalogue becomes something to link FROM rather than an owner, and a pull must
never wipe a locally created item.

**One sales order per batch (10).** The owner believes this needs no jouma change because
Dishflow does it. That is being verified before anything is built: Dishflow books through
its own FastAPI backend and a different addon, so its contract is not automatically ours.
The instruction to that lane is explicit: establish whether one-sales-order-per-batch can
be done against the existing `create_from_offline_pos` by shaping the payload differently,
and if it cannot, report the evidence and leave the decision to the owner rather than
inventing an endpoint. The standing rule that no new module endpoint may be added still
holds.

**TO GO (2).** Chosen as its own order type with an optional table, so it occupies the
floor like a dine-in but bills and prints as what it is. Adding a value to OrderType
reaches persistence, the tax matrix, reports and the wire payload, so the local
distinction is kept local and the wire keeps a value the module already accepts.

## Arabic printing, which is the one that stings

Phase 1 shipped a per-line raster path and a WPC1256 code page, its tests pass, and the
owner says Arabic still does not come out on paper. The tests could not have caught it:
the widget-test font draws every rune as a box, so they proved geometry and bit packing,
never glyph shapes. The lane working on it has been told to read Dishflow's
`arabic_escpos_renderer.dart` properly (it is the proven solution on this hardware in this
market), find the concrete reason ours produces nothing usable, and add a test that writes
the rendered receipt to a PNG so a human can look at real Arabic instead of trusting a
green test.

The general lesson, recorded because it will happen again: a test that cannot fail for the
reason the feature would fail in the shop is not evidence.
