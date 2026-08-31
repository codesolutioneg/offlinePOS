# Dishflow parity: the finalize plan

The mission, in one sentence: a cashier who worked on Dishflow sits at offlinePOS and
finds every button, screen, setting and flow they expect; when the internet dies they
notice nothing except the badge; when it comes back everything syncs correctly as if
nothing happened.

This document is the complete, self-contained work plan to get there. It was produced
by diffing full Dishflow inventories (UI, settings, features, architecture, plus
scenarios reconstructed from its integration tests and docs) against offlinePOS at
HEAD `c1f02f6`, with every claim verified in code. The raw inventories live in
`docs/DISHFLOW_PARITY_CHECKLIST.md` (DETAILED FINDINGS sections); this file is the
actionable layer on top.

State of the offline requirement today: **already met**. An audit of every place a
network loss is user-visible found exactly two intended surfaces (the online/offline
badge with pending count, `lib/features/sell/sell_screen.dart:1612-1650`, and honest
status text at shift close and on stale prices). Everything else (sign-in, dine-in,
modifiers, discounts, split/merge/move, hold/recall, void/refund, kitchen print,
receipt print, drawer, X/Z, all reports, staff edits, floor edits) is identical
offline, because every store is local SQLCipher and the sync loop is read-only
(`lib/core/sync/sync_service.dart:150-158`, proven by the test "refresh never drains
the outbox"). **Every item below must preserve this: new features are built on local
stores and LAN events, never a network call on a selling path.**

---

## Rules for whoever executes this (read before writing a line)

Repo: `/home/username/workspace/offlinePOS`, branch `main`. Baseline: 1506 tests
passing + 1 skipped (staging, needs STAGING_URL), `flutter analyze` clean on the
whole project. Keep both. That count is a local run with the six socket-binding
suites left out, because they hang in a sandbox; CI runs the lot on Windows, so a
green AppVeyor build is the number that covers everything.

Hard constraints, none negotiable:

1. **No server changes on either side.** Dishflow's Firebase is not touched, ever.
   offlinePOS never talks to Firebase. The Odoo contract is FIXED at
   `sale.order.create_from_offline_pos` plus reads of standard Odoo models through the
   generic `call_kw` path (`lib/core/sync/odoo_sender.dart`). No new endpoints in the
   jouma `pos_offline_sync` module. Anything needing one is listed under
   "Blocked by rule" and stays unbuilt.
2. **A sale never waits on the network, the LAN, or any lock.** Selling paths stay
   synchronous (`lib/app/pos_session.dart` is the reference for the discipline).
3. **Orders push as ONE batch at shift close** (or manual Support > Sync now). The 20s
   loop stays read-only. Single shared Odoo login, license limit; this is a product
   rule, not a preference.
4. **The outbox is append-only, idempotent, unique on (kind, payload_uuid).** Replay
   is a no-op. New local-only order fields are stripped in `Order.toServerPayload()`
   (`lib/domain/order.dart:362-386`) so the wire contract never grows by accident.
5. **Schema changes are additive only**: bump `Schema.version` in
   `lib/core/db/schema.dart` and append a migration list entry. Never rewrite one.
6. **No new pub dependencies** without an explicit decision from Osam.
7. House style: short comments explaining WHY; no ticket numbers, no names, no em
   dashes anywhere, no AI or tool attribution; prose voice like
   `lib/core/sync/outbox.dart`. Every user string goes through `tr()` with an Arabic
   entry in the `_ar` map in `lib/core/i18n/l10n.dart`.
8. Git: another session may work in this tree. Stage only your own files by explicit
   path. Never `git add -A`, never stash/reset/checkout/rebase/clean. Atomic commits,
   lowercase area prefix, imperative ("sell: ...", "lan: ...", "reports: ...").
9. Definition of done per item: `flutter analyze` clean, `flutter test` green with new
   tests for the behaviour, the offline drill (does the feature behave identically
   with no network?), and the strings exist in Arabic. Before any push: the standard
   review chain (self-review + codex; median only if asked).
10. When an item conflicts with something in the code, trust the code and say so;
    when it conflicts with a rule above, the rule wins and the item gets re-scoped.

---

## Phase 1: day-one blockers (P1)

These are the four things a real shop notices on day one. Do them first, in this
order.

### 1.1 Arabic text on printed receipts and kitchen tickets
The UI is fully bilingual (400+ Arabic strings) but the ESC/POS layer is text bytes
through a single Windows-1252 code page, so every Arabic product name prints as
fallback characters (`lib/core/printing/escpos.dart:49-72,86,134`). An Arabic-menu
restaurant cannot hand out a readable receipt. Dishflow solved this with a 2,228-line
raster renderer.
- Steps: add a raster-line path in `escpos.dart`: when a line contains runes
  `byteFor` cannot map, render THAT LINE with Flutter `TextPainter` to a 1-bit bitmap
  and emit `GS v 0`; keep the byte path for fully mappable lines (the file's own doc
  at :77-80 explains why full-receipt rasterising is rejected; per-line only). RTL
  shaping comes free from Flutter text layout; pick direction per line content. No
  call-site changes in `ReceiptBuilder`/`KitchenTicketBuilder` (they compose EscPos
  primitives). Settings toggle `receipt_arabic_raster`, default on when language is
  ar. Optional: CP864/CP1256 code-page tables selectable per printer.
- Tests: Arabic string emits `GS v 0` and zero fallback bytes; mixed receipt keeps
  the byte path for Latin lines; goldens for receipt and kitchen ticket; toggle test.

### 1.2 Service charge
A table-service restaurant here bills a service percentage (Dishflow defaults 12%).
offlinePOS has no concept of it; order total is
`subtotal * discountFactor + deliveryCost + tip` (`lib/domain/order.dart:297`).
- Steps: `SettingsStore` keys `service_charge_percent` (double, 0 = off) and
  `service_charge_order_types` (default dine-in only). STAMP `serviceChargePercent`
  onto the `Order` at creation/recalc, not read live, so a saved order's total never
  changes when the setting does; include in `total` and `toMap`/`fromMap`; keep it in
  the wire payload the way discounts already fold in (check how the module books
  totals: the safest is folding it into line pricing or a service line consistent
  with the delivery-charge treatment in `toServerPayload`). Print as its own line in
  `ReceiptBuilder` between subtotal and total. UI in `TaxSettingsScreen` or
  `ShopSettingsScreen`, gated `Permission.openSettings`.
- Tests: dine-in charged, takeaway not; stamped value survives round-trip and a
  settings change; receipt line; split/merge math keeps the charge consistent.

### 1.3 Pre-bill: print the bill before payment
Dine-in customers ask for the bill; the waiter prints it and brings it over. Today
paper only exists after payment (`lib/app/pos_app.dart:395-444`).
- Steps: `ReceiptBuilder.buildBill(Order)`: same layout, titled BILL, no
  payment/change section, no drawer kick, marked "not a tax receipt". Add
  `onPrintBill` to `SellScreen` with a "Print bill" entry in the `_billOptions` sheet
  (`sell_screen.dart:1211-1280`) plus an icon near the totals when there are lines,
  and on the open-orders card. Wire in `pos_app.dart:_selling` via the existing
  spooled receipt printer, reference `bill-<uuid>-<ts>`. Audit `bill.printed`.
- Tests: button appears with lines and fires; bill bytes contain BILL, no payment
  rows, no drawer-kick sequence.

### 1.4 Edit or cancel a paid, not-yet-synced order
"Rang it wrong / customer added an item right after checkout" is a daily flow.
Today a paid order is only reachable in history with Reprint and Refund
(`lib/features/orders/order_history_screen.dart:262-277`).
- Steps: `OrderStore.reopen(uuid)`: paid to draft, allowed ONLY while state is not
  synced; remove or supersede the queued `order.push` outbox row. "Edit order" button
  on the order detail for paid orders, gated by a new `Permission.amendOrder`
  through the existing `_authorize` (`pos_app.dart:1285-1294`). On edit: reopen,
  `session.recall(uuid)`, back to the sell screen; audit `order.amended` with the old
  total. On re-payment: kitchen fires only unsent lines (existing behaviour), receipt
  marked amended, deletion slip for removed lines (`_printDeletion`,
  `pos_app.dart:377-393`). "Cancel sale" for paid-unsynced = full-quantity refund
  shortcut through `RefundScreen` (keeps the books append-only). An already-synced
  order can NEVER be amended (the server treats a repeated uuid as a duplicate ack,
  `odoo_sender.dart:130-134`); the answer there stays refund + re-ring.
- Tests: edit visible for paid, hidden for synced; reopen rejects synced; the outbox
  row is gone; audit recorded.

---

## Phase 2: real-shop parity (P2)

Grouped by theme. Within a theme the order is the build order (later items reuse
earlier ones).

### A. Selling flow

**A1. Fixed-amount discounts.** Percent-only today
(`settings_store.dart:111-126`). Toggle `allow_amount_discount` (default off) on
`DiscountSettingsScreen`; the discount dialog accepts an amount and converts to an
equivalent percent at apply time so `Order`/receipt/reports stay percent-based (no
schema change), still capped by `maxDiscountPercent`. Tests: amount converts
correctly and respects the cap.

**A2. Customer on ANY order type.** Picker exists only inside the delivery dialog
(`sell_screen.dart:325-384`, context bar gates on delivery at :1837-1853), while
`Order` already carries `partnerId`/`customerName`. Add a Customer chip to
`_contextBar` for all types; "Walk-in" clears (the picker already returns 'clear',
currently unhandled at :371-375); "Add new" opens the existing customer form
(extract from `customer_management_screen.dart`); customer line on the receipt.
Tests: chip on dine-in/takeaway sets partnerId; clear works; receipt line.

**A3. Human order number.** Only `#shortRef` (uuid prefix) exists
(`receipt_builder.dart:94,240`). Per-device daily counter; stamp
`orderNo` = `DDMM-SEQ-<tillTag>` (tillTag derived from device id so LAN peers never
collide) at pay/hold in `pos_session.dart`; persist in `toMap`/`fromMap`, STRIP in
`toServerPayload()`; render on receipt, kitchen ticket, KDS card, history, open
orders; reset at the business-day cutover (`lib/domain/business_day.dart`). Tests:
round-trip + payload strip + rollover.

**A4. Kitchen-print failure visibility.** A spooled kitchen ticket currently reads
as success: the cashier always sees "Sent to kitchen"
(`sell_screen.dart:1033-1043`) while the ticket sits in the spool
(`pos_app.dart:1376-1405`). During a rush, food silently does not cook. Make
`_fireKitchen` return (sent, spooled, lost); toast amber "Ticket held, printer
offline, will print automatically" when spooled, red when lost; small spool badge
next to the online chip. Tests: fake registry failing one station.

**A5. Modifier auto-add defaults (P3, do with A1-A4 if cheap).** Dishflow skips the
modifier sheet when defaults resolve; offlinePOS always opens it
(`sell_screen.dart:298-312`). Add `autoAdd`/default flags to `ModifierGroup` +
puller mapping; bypass the sheet when every group resolves.

### B. Delivery (without the dispatch system, which stays excluded)

**B1. Delivery receipt must carry phone/address.** `ReceiptBuilder` prints only the
customer name (:98); a driver cannot take the slip and go. Print phone + address
lines for delivery orders on receipt and kitchen ticket header. Tests: builder.

**B2. Delivery zones with preset fees.** Fee is free-typed every time
(`sell_screen.dart:984-988`). Zone list (name + fee) in `SettingsStore` with a
small editor (model: `quick_comments_screen.dart`); zone chips in the delivery
dialog fill the cost field; free-typing stays as override. No SLA timers (dispatch
exclusion). Tests: round-trip; picking sets fee.

**B3. Delivery channels (aggregators).** No channel concept
(`OrderType` = dineIn/takeaway/delivery only). Channel list in `SettingsStore`
(name + optional `partnerId` from the pulled partners); channel picker +
company-order-number field in the delivery dialog; channel sets
partnerId/customerName (already in the payload contract); wire `order_type` stays
`delivery`, channel + companyOrderNo stay local-only (stripped). Group by channel
in the payment-analysis and sales reports. Per-company price overrides: deferred,
needs a pricelist concept. Tests: payload strip; report grouping.

**B4. Drivers, minimal.** Local `drivers` store (name, phone, active);
`driverName` on `Order` riding into the note part of the payload; picker on the
delivery context chip; Open orders filtered to delivery as a minimal board with
driver + age. No cloud, no dispatch SLA. Tests: store CRUD; board filter.

**B5. Resume-vs-new prompt for parked deliveries (P3).** When held delivery orders
exist, the floor's Delivery button offers resume-or-new instead of always new.

### C. Shift and day

**C1. Business-day cutover hour setting.** `BusinessDay.of` takes a cutover hour
but the caller never passes it (`order.dart:321`). Key `business_day_cutover_hour`
(default 4); stamp business_date at save; field in ShopSettingsScreen. Tests:
boundary; a 03:00 sale lands on yesterday with cutover 5.

**C2. Shift-open nudge at sign-in.** A cashier who forgets the shift gets a Z with
no float. On `_signedIn` (`pos_app.dart:295`), if no open shift, one-tap banner
"No shift open, open with float?". Tests: banner shows/routes.

**C3. Stale-shift detection.** Yesterday's shift silently absorbs today's sales.
At sign-in compare `shift.openedAt` against the business-day boundary; banner
"Shift open since yesterday, close it first". Tests: boundary fixture.

**C4. Shift-close guard on open work.** Close currently ignores held orders and
unfired course lines (`pos_app.dart:1466-1492`). Before `authorizeClose`, count
held orders + pending fireAt lines, show the list, allow manager override. Tests:
held-order fixture.

**C5. Per-cashier flash.** X read is till-wide only (`shift_screen.dart:361-371`).
`ShiftStore.summaryByCashier` splitting by `Order.cashierId` within the shift
window; "Cashier flash" button next to Print X, cashier picker, print via the
existing `onPrintReport`. Tests: per-cashier rows sum to the shift total.

### D. Reports

**D1. Expenses report across shifts.** Paid-outs exist only inside each shift
(`shift_screen.dart:83-144`). `ShiftStore.movements(from,to)` across closed
shifts; screen grouped by category using the hub's range/cashier plumbing; hub
tile; CSV. Tests: mirror the discounts report test.

**D2. Refunds/voids money report.** Refunds are reversal orders, voids audited,
but only the raw activity log surfaces them. Filter `OrderStore` on
refund-of + join audit `line.voided`/`order.cancelled`; totals by reason and
cashier; hub tile; CSV.

**D3. Sales by day-of-week + period comparison.** Pure aggregations: day-of-week
bucket beside the existing hour bucket; hub fetches two ranges and diffs KPI rows.

**D4. Today-at-a-glance card.** Orders count, gross, cash vs card, open tables
from `OrderStore.recent` + `ShiftStore.summary`, as a header strip on the floor
(not pick mode) or top tile of the hub; money gated `Permission.viewReports`.

**D5. Modifier analysis (P3).** Aggregate `OrderModifier` by id/name over the
period; screen + tile + CSV.

### E. Settings and ops

**E1. Sub-receipt (no-price copy).** Keys `sub_receipt_station` (empty = off) +
`sub_receipt_hide_prices`; one extra `ReceiptBuilder` pass with prices off, sent to
the configured station; picker in PrintersScreen. Tests: second job, no price
column.

**E2. Receipt logo.** Respect the text-only ESC/POS stance: NV-flash route (one-time
"upload logo to printer", `FS q`/`GS ( L`) + toggle `receipt_print_logo` emitting the
print-stored-logo command (2 bytes per receipt). Raster fallback only behind a
clearly-gated option. Toggle + preview in the receipt designer.

**E3. Payment-method printed labels.** Key `payment_method_labels` (id to label)
applied at receipt build and in the payment dialog; small "Payment methods" screen
listing synced methods with editable labels. Tests: override prints.

**E4. Menu-refresh latency.** A price change in Odoo takes up to 6h to reach the
till (`sync_service.dart:34,227`). Add `force` to `SyncService.refresh`, a "Refresh
menu" entry in the settings hub, fire a pull on sign-in, surface `refreshedAt`
sooner than the 24h banner. Tests: force bypasses the age gate; loop stays
read-only for orders.

**E5. Onboarding checklist.** 4 of 5 wizards are unmounted (`pos_app.dart:308`).
Mount `firstSignIn` for the Setup account; a setup checklist card while
endpoint/catalogue/printers are unset; dismiss forever once complete.

**E6. Server "Test connection" button (P3).** Same `version_info` probe with a
spinner and pass/fail text on the server settings screen.

**E7. Custom roles.** Storage already supports arbitrary role strings
(`settings_store.dart:432-439`); only the UI locks to manager/cashier. Key
`custom_roles`; add/rename/delete cards on RolesPermissionsScreen via the existing
permission plumbing; roster dropdown lists them; manager undeletable.

**E8. Whole-database backup export.** "Backup" action in Diagnostics: checkpoint
SQLite, export the encrypted DB file via the existing export path; stays
SQLCipher-encrypted. Tests: file exists, source DB usable.

**E9. Email Z-report.** Per-device SMTP settings (host/port/ssl/user/password,
DB is encrypted at rest) + recipients; send at shift close best-effort with a
queued retry; NEVER blocks cash-up. Do email first; a WhatsApp transport can share
the sender abstraction later if asked. Tests: fake SMTP; failure never fails close.

**E10. Backup printer failover.** The spool retries a dead printer but nothing
reroutes: optional backup printer per printer in the registry; transport tries
primary, then backup with a REROUTED header, then spools. Tests: failover; spool
behaviour unchanged.

**E11. On-demand Odoo customer search past the 500-partner pull.** When online,
the customer picker falls back to a `call_kw` `res.partner` search_read with the
typed term (allowed read), merging hits into the local cache; offline stays local;
never on the payment path.

### F. Multi-till wave (build on the LAN fabric; all local + LAN events, no cloud)

**F1. Shop-wide 86 board.** Availability is per-till
(`settings_store.dart:303-317`). New `product.availability` LAN event kind,
published from `settings.setProductAvailable`, applied by the fabric. Tests:
replication convergence.

**F2. Cross-till settle (take over a tab).** The floor refuses another till's tab
(`pos_app.dart:996-1006`), which is correct as a default, but a waiter-handheld +
counter-cashier shop needs a gated takeover: an `order.claim` LAN event where the
claimer becomes the owner after an ack from the owning till (single-writer rule
preserved); "Take over" behind a manager-level gate; audited both sides; a claim
while the owner is offline is refused. Tests: partition case.

**F3. Cross-till day-close coordination.** Shift lifecycle events (opened/closed
with business_date, device, cashier) over the fabric; a Z-close on one till warns
or blocks new orders on the others per a policy setting; an offline till learns of
the close on rejoin and prompts its own. Never blocks a sale on fabric
availability.

**F4. Customer-facing display.** Publish the open cart as a LAN event from
`PosSession` mutations; a display-only device mode exactly like `kdsMode`
(`pos_app.dart:483-517`) rendering the chosen till's cart plus an idle panel.

**F5. Multi-cashier table security + transfer (single till).** Optional toggle
`table_security` (default off): resuming another cashier's tab prompts that
cashier's PIN or a manager override; a manager "Transfer tables" action rewrites
cashierId on held orders with audit. Tests: prompts when on, free when off.

**F6. Table reservations (P3).** Local `reservation_store` (uuid, table, name,
phone, time, covers, state) + due-soon badge on the floor tile + a
`reservationUpsert` LAN event kind.

---

## Phase 3: polish (P3, take in any order after Phases 1-2)

- Dark mode: `darkTheme` + `themeMode` + one settings toggle
  (`pos_app.dart:464-475`).
- Product images on grid tiles: pull `image_128` via existing `call_kw`, additive
  `products.image` BLOB, tile background behind a toggle.
- Keyboard shortcuts: F12 opens the payment sheet, Ctrl+K focuses search
  (`Key('search')`, `sell_screen.dart:1682`).
- Guest-count prompt on seating, behind `ask_guest_count` (default off).
- `priceOverride` permission is mislabeled: it gates 86/favourites
  (`sell_screen.dart:281`), not price. Either rename or implement a real per-line
  price override (audited).
- Table state colours editable; receipt font-size profiles (`GS ! n`); category
  chip styling. Low value, cheap.
- Attendance hours report: range read over `AttendanceStore`, totals per staff per
  day, CSV.
- Manager TOTP second factor: additive `totp_secret` on users, RFC 6238 check in
  the elevation dialog, fully offline.
- Cost-vs-sales + menu engineering reports: need `standard_price` in the puller +
  `products.cost` column first (additive), then margin x popularity quadrants.
- Pay-later / on-account tender: needs A2 (customer on order) first; distinct
  payment label; receivables row in reports; blocked without a customer.
- Per-role allowed order types; optionally per-report `viewReports` split.

---

## Follow-ups from already-shipped work

1. ~~**Live shop-key rotation.**~~ DONE. The credential reads the key at the moment
   of each request and rebuilds its hash only when the key changed, so rotating
   unpairs from the next request. The dialog no longer mentions a restart. The
   sharing switch itself still needs one for off-to-on, and says so.
2. ~~**Persist the close-flush retry arming.**~~ DONE. (armedAt, reason) live in
   `app_settings` and are read back before the first tick. Only the arming is
   persisted, never "pending > 0", so mid-shift sales still wait for the close. An
   arming whose window closed while the till was off reports that it gave up
   instead of starting a fresh window.
3. ~~**Update install execution.**~~ DONE for Windows, which is what CI packages: a
   detached PowerShell handoff waits for this process to exit, unpacks the verified
   zip over the install directory and restarts the app. Every path in the script is
   a quoted literal, and a handoff that cannot start throws so the service keeps
   the build and retries. Off Windows there is no installer and a verified build
   stays staged for an operator, deliberately.
4. **Two-till hardware test.** STILL OPEN, and it needs hardware rather than code.
   The fabric is proven in-memory and over loopback, never on two machines.
   Protocol: enable sharing on till A, copy the shop key to till B, restart B; both
   appear in each other's peer lists; park a table on A and see it busy on B; ring,
   bump on KDS, status lands on A; pull B's cable, sell on both, replug, converge
   with no duplicates. Do this before any real shop.
5. ~~**AppVeyor**~~ CONFIRMED green: build 1.0.101 on `f95e68a`, which runs
   `flutter analyze`, the full `flutter test` including the socket-binding suites
   that cannot run in a sandbox, and the Windows release build.
6. **Which jouma branch is production.** Found while tracing the batch question and
   listed here because it is upstream of it. `pos_offline_sync` on jouma `main` is
   still the old `pos.order` variant (18.0.1.0.0, `models/pos_order.py`); only
   `Staging_final` and `Staging_osam` carry the `sale.order` cascade this till
   actually calls (18.0.3.0.0, `models/sale_order.py`). A till pointed at a jouma
   running `main` gets `AttributeError` on `sale.order.create_from_offline_pos` and
   books nothing. Establish what is deployed before shipping anything.

---

## Decisions Osam must make (do NOT build without an answer)

| Topic | Question | Default |
|---|---|---|
| Coupons | Prior decision excluded them (needs Odoo models), but a purely LOCAL coupon store (code, percent/fixed, uses) is feasible and was sketched. Build local coupons? | Excluded |
| Loyalty points | Same shape: local accrual is feasible after A2, but the prior decision excluded loyalty. | Excluded |
| ETA e-invoicing | Belongs server-side in Odoo at booking, not on the till. Confirm it stays out of the till. | Out of the till |
| Kiosk / QR menu / customer app | Excluded by prior decision. | Excluded |
| Delivery dispatch (drivers with SLA boards, zones with timers) | Excluded; B2/B4 above deliver the local-only slice. | Excluded beyond B2/B4 |
| Intraday cloud visibility of sales | Conflicts with batch-at-close product rule. The opt-in "push as rung" flag idea exists if the license situation ever changes. | Not doing |
| Per-company aggregator prices | Needs a pricelist concept. | Deferred |
| Fingerprint hardware / ZKTeco | Not carried over. | Not doing |

## Blocked by rule (needs a new server endpoint; listed so nobody rediscovers them)

Shift/Z push to Odoo; audit + device-status server sink (senders are wired as no-ops,
`odoo_wiring.dart:50-51`); customer push with partner_id backfill; attendance push
(cheaper route if ever wanted: standard `hr.attendance` via `call_kw`, a fresh
decision); roster distribution; central till-config distribution; booking till
expenses into Odoo; consolidated end-of-day invoice / attaching session PDFs;
amending an already-synced order server-side; post-close payment adjustments;
remote fleet administration.

## Already covered, equal or better: do not rebuild, do not regress

Login with Argon2id + lockout; the entire sell core (grid, categories, search,
modifiers with min/max/required, notes, gated discounts, void with slips, 86,
favourites, barcode, weighed items, course firing); order types + delivery capture;
the drawn table floor (better than Dishflow's); bill surgery (split even / by guest /
pay selected / move / merge, 21 headless tests); the payment sheet (split tenders,
tips, change); hold/recall + open orders; kitchen routing per category AND per
product with fallback + KDS device mode (better: Dishflow's KDS misses unpaid
dine-ins); receipts (designer, copies, drawer kick, no-sale slip, durable spool);
shift/cash management with float, X/Z, counted cash + variance (Dishflow has none of
that); history + true partial refunds (Dishflow has cancel-only); the 10-report hub
with CSV/PDF; the audit log; staff/roles/attendance; AR/EN RTL UI; the LAN fabric
with pairing; signed pinned updates; the onboarding wizard frame; crash recovery of
the open order. Also deliberate non-copies from Dishflow: its missing PIN lockout,
missing float, silent zero-snapshot close, admin-PIN-as-Odoo-password fallback,
unaudited bulk deletes, world-open Firestore rules. Those are the moat; protect them.

## Suggested commit-sized slices (Phase 1 first)

1. `print: raster fallback for lines the code page cannot carry` (1.1)
2. `print: arabic goldens for receipt and kitchen ticket` (1.1 tests)
3. `sell: service charge stamped per order` + `settings: service charge controls`
   + `print: service charge line` (1.2)
4. `print: a bill before payment, marked not a receipt` + `sell: print bill action`
   (1.3)
5. `orders: reopen a paid unsynced order` + `sell: edit a paid order back into the
   cart` + `orders: cancel-sale shortcut through refund` (1.4)
then Phase 2 by theme, one commit per lettered item or finer.
