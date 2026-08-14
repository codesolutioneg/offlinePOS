# Dishflow parity: gap checklist for offlinePOS

Goal: offlinePOS mirrors everything Dishflow does and does it better (offline-first,
local store as source of truth, Odoo as the sync destination, no cloud dependency at
sale time). This document holds the findings gathered so far as an actionable
checklist plus the full detailed inventories behind them.

Status: PARTIAL, and the gap in the analysis matters as much as the gaps it found. Of the
five comparison dimensions, only one produced a gap list. The run was stopped mid-way to
save budget.

## Analysis pipeline status

Produced:
- [x] INVENTORY: offlinePOS — Current-State Inventory (branch `main`, HEAD `8df1d1d` "sell: keep the tip on a split-share payment out of the balance", 136 commits) (`wf_af146bcc-b17`)
- [x] INVENTORY: Dishflow (DishFlow) UI Screens + Navigation Inventory (`wf_af146bcc-b17`)
- [x] INVENTORY: Dishflow POS: Settings + Configuration Surface Inventory (`wf_af146bcc-b17`)
- [x] INVENTORY: DishFlow POS — Functional Features + Backend Inventory (`wf_af146bcc-b17`)
- [x] INVENTORY: offlinePOS Architecture + Odoo Sync Inventory (`wf_d47a146c-ac5`)
- [x] INVENTORY: Dishflow POS: Backend + Data Architecture Inventory (`wf_d47a146c-ac5`)
- [x] GAP LIST: architecture + Odoo sync state parity (15 items, the CHECKLIST below)

Never produced, so do not read their absence as "no gaps found":
- The four other gap lists (**UI and sequence, settings, features, user scenarios**) were
  **never generated at all**. The run that would have turned the inventories into gap
  lists was stopped to save budget, so those four dimensions have raw inventories below
  and no comparison on top of them. Read the inventories directly until the run finishes.
- **No adversarial re-check ran**, on the architecture gap list or on anything else. The
  15 items below are pre-verification: evidence-based, but their file references are worth
  re-confirming while implementing.
- One of the five Dishflow inventories did not finish; which one is only visible on resume.

Resume commands (cached agents replay for free, only unfinished ones rerun):
- Workflow scriptPath `.../workflows/scripts/dishflow-offlinepos-gap-wf_af146bcc-b17.js` with resumeFromRunId `wf_af146bcc-b17`
- Workflow scriptPath `.../workflows/scripts/dishflow-offlinepos-architecture-gap-wf_d47a146c-ac5.js` with resumeFromRunId `wf_d47a146c-ac5`
- Scripts dir: `/root/.claude/projects/-home-username-workspace-offlinePOS/6e70b0bc-7e6a-416d-81b8-e0285eb514aa/workflows/scripts/`


---

# CHECKLIST: architecture + Odoo sync state parity

NOTE: pre-verification (the adversarial re-check did not run). Evidence-based, but re-confirm file refs while implementing.

How each item is marked, since most of them are now decided rather than pending:

| Mark | Meaning |
|---|---|
| `[x] done` | Built and tested. The commits and the file that proves it are listed under **Built** |
| `[-] NOT DOING` | A decision, with the reason: it needs a new server endpoint, or it conflicts with a product rule. The plan steps are kept for whoever revisits it |
| `[-] OUT OF SCOPE` | Not the offline till's job, by a decision taken before this analysis |
| `[ ] NEXT WAVE` | Genuinely still to do, and worth doing next |

Because of those decisions, the goal at the top of this document reads as "match what a
shop actually needs, and beat Dishflow where it matters", not "implement every Dishflow
feature". Several items below are deliberately not being matched.

The reason behind most of the `NOT DOING` items is one rule: **the till builds nothing
that requires a new server endpoint.** The contract is one write call plus reads of models
the customer's database already has (docs/ODOO_SYNC.md). Every gap below that needs a new
entry point in the Odoo module is therefore not a backlog item waiting for time, it is a
decision that would have to be taken again, with the module change, its review and its
deployment priced in.

## P1

### [x] LAN-first multi-device state fabric (till-to-till replication)  `done`

**Built:** device-to-device on the shop LAN, nothing from Odoo. Protocol spec in
docs/LAN_SYNC.md.

| Part | Commit | Proof |
|---|---|---|
| Append-only event log, cursors, clocks (schema v15) | `80880be` | `lib/core/lan/lan_event_log.dart`, `lib/core/db/schema.dart` |
| Applier writing through the existing stores, with the money/food read split | `bb0c45d` | `lib/core/lan/lan_applier.dart`, `lib/core/db/order_store.dart` |
| Beacon discovery, HTTP transport, replicator | `4ffe14b` | `lib/core/lan/lan_beacon.dart`, `lan_transport.dart`, `lan_fabric.dart` |
| Startup wiring behind a device switch | `a462adb` | `lib/core/lan/lan_wiring.dart`, `lib/main.dart` |
| Shop network screen from the settings hub | `720dad3` | `lib/features/settings/lan_settings_screen.dart` |
| Deferral of a bump whose order has not arrived | `828f39f` | `lib/core/lan/lan_applier.dart` |
| Pairing on a shared shop key | `b121f4b`, `3fbacc5` | `lib/core/lan/lan_credential.dart` |

Tests: `test/lan/` (two shops converging, partition and heal, a replicated paid order is
never re-enqueued, a sale never waits on the fabric, pairing refusals, deferred status).

**offlinePOS before this:** Zero inbound network capability: grep ServerSocket|HttpServer|WebSocket|multicast|RawDatagramSocket over /home/username/workspace/offlinePOS/lib/ returns nothing; the only sockets are outbound TCP 9100 to printers (lib/core/printing/printer_transport.dart) and HTTPS to Odoo (lib/core/sync/http_post.dart). All shared-state categories (orders, held orders, pos_tables, shifts, settings, 86 list) live in the per-device SQLCipher DB (lib/core/db/schema.dart v1-v13) with no replication. Held orders and table occupancy on till A are invisible on till B.

**Plan steps:**
1. Define a replicated till-event model in lib/domain/ (order upsert, kitchen status change, table move/merge, 86 toggle, customer added) keyed by (device_id, monotonic seq) with the order uuid as identity, reusing the existing payload-is-truth toMap() shapes from lib/domain/order.dart.
2. Create lib/core/lan/: peer discovery via UDP beacon or mDNS reusing the subnet-sweep pattern already proven in lib/core/printing/printer_discovery.dart; each till serves a small HttpServer/WebSocket on a fixed port, LAN only, no internet dependency.
3. Add a per-peer replication cursor table in lib/core/db/schema.dart (v14, additive per the stated policy); pull-based catch-up on rejoin plus push notify when connected; conflict rule last-write-wins per field with device_id tiebreak; replication must never block a sale (same synchronous no-await discipline as lib/app/pos_session.dart).
4. Apply inbound events through the existing stores (OrderStore.save/setKitchenStatus, TableStore, SettingsStore) so the local DB remains the single source of truth and every existing screen works unchanged.
5. Tests in test/lan/: two in-memory DBs converge; partition then heal replays idempotently by uuid; a replicated paid order is NOT re-enqueued to the receiving till's outbox (only the originating till pushes to Odoo).
6. Docs: rewrite docs/ARCHITECTURE.md multi-device section (currently single-device reality) and add docs/LAN_SYNC.md protocol spec.

**Do it better than Dishflow:** Dishflow's cross-device layer dies the moment internet drops because Firestore is the coordination SPOF (its inventory section 10). A LAN fabric keeps till-to-till, KDS, and table sharing alive during an outage, with no cloud cost and no world-open rules.

### [x] Kitchen display on a separate device (order-state propagation to KDS)  `done`

**Built:** `1c52422`. `KDS_MODE` boots a device straight into the board with no sign-in and
no open shift (`lib/app/pos_app.dart` `_kitchenOnly`, `lib/features/kitchen/kitchen_display_screen.dart`
for the app-bar door to the shop network screen), and `lib/core/config/till_config.dart`
makes a kitchen build default to sharing, since a KDS off the LAN is a blank screen. Tickets
arrive as `order.upsert` and a bump leaves as `kitchen.status`, so the board never claims a
sale: `lib/core/db/order_store.dart` `kitchenTickets()` is shop-wide while every money read
stays scoped to the till. Tests: `test/app/kds_mode_test.dart`, `test/lan/lan_replication_test.dart`.

The printed ESC/POS ticket is untouched and stays the answer for a kitchen with no screen.

**offlinePOS before this:** A KitchenDisplayScreen exists but only as a screen on the SAME till reading the local DB: /home/username/workspace/offlinePOS/lib/app/pos_app.dart:819-822 wires load: () => widget.orders.kitchenTickets() and onStatus: orders.setKitchenStatus; order_store.dart:85-97 reads/writes the local orders table. KitchenStatus enum and per-line firedStations/printedToKitchen exist in lib/domain/order.dart. A dedicated KDS device would see nothing. Kitchen ticket PRINTING to LAN stations works (lib/core/printing/kitchen_ticket.dart, station routing in settings_store.dart:154-292), so paper KOT is the only cross-device kitchen channel today.

**Plan steps:**
1. Build on the LAN fabric (previous item): KDS subscribes to order events filtered to kitchen-relevant states, exactly the feed kitchenTickets() computes locally.
2. Add a KDS mode to lib/core/config/till_config.dart (--dart-define=KDS_MODE) that boots straight into the kitchen screen with no selling UI and no shift requirement.
3. Status changes tapped on the KDS emit events that replicate back and land via OrderStore.setKitchenStatus on the owning till, so paid/synced lifecycle is untouched.
4. Keep the ESC/POS kitchen printer path as the degraded mode for shops without a KDS (already complete, including re-fire printing only new lines).
5. Tests: KDS round-trip over the fabric (ring on till A, appears on KDS, bump on KDS, status lands on till A); course-firing fireAt interaction with the replicated feed.
6. Docs: docs/ARCHITECTURE.md kitchen section.

**Do it better than Dishflow:** Dishflow's KDS freezes when internet drops (snapshots stall on the cloud). A LAN-fed KDS keeps working through an outage, and status writes are ordered per till instead of last-write-wins blind updates on a cloud doc.

### [-] Shift/session data never reaches Odoo (Z report, cash counts, variance)  `NOT DOING`

**Decision: not doing it, because it would need a new server endpoint.** Booking a cash
session is a write Odoo has no ready call for, so this is a module change, not a till
change. The shift is deliberately a till-local artefact: it is read on the device as the X
and Z figures, now including **per-tender totals** so a Z read reconciles against the
drawer count without re-deriving which methods are cash (`6f67585`, `8226ba1`,
`lib/core/db/shift_store.dart`, `lib/features/shift/shift_screen.dart`).

Step 1 below was done anyway and is the only part that was: a shift carries a `uuid`
(`6f67585`, schema v14). Nothing reads it. It means that if this decision is ever revisited,
the shift is already replay-safe on a key and the work is a sender plus an entry point,
not a migration in the same release.

**Dishflow has:** Central shift/session state: cashier_shifts docs with isLocked+sessionId (cashier_shift_service.dart:258-335), active_sessions/{connectionId} lifecycle with transactional open and deterministic session id (active_session_service.dart:348-420), and session_adjustments written at every close with per-method totals (firebase_session_adjustment_service.dart:15-40). Back-office reports read all of it.

**offlinePOS today:** Shifts are complete but entirely local: lib/core/db/shift_store.dart + lib/domain/shift.dart (opening float, cash movements, closing count, X/Z summary, expectedCash/variance). The shift-close hook onCloseSync (/home/username/workspace/offlinePOS/lib/app/pos_app.dart:1350-1368) only reconciles and flushes ORDERS. Grep proves the only outbox kinds are order.push, audit.push, device.status (pos_session.dart:328,353,545; sync_service.dart:150,163; pos_app.dart:790); there is no shift.push. The opening float, drawer movements, counted cash, and over/short never leave the till, so the back office has no cash-reconciliation record at all.

**Plan steps, kept for whoever revisits the decision:**
1. Add a uuid column to the shifts table (lib/core/db/schema.dart v14, additive) so a shift has a replay-safe identity like orders do. **Done** (`6f67585`).
2. Extend the pos_offline_sync module contract (documented in docs/ODOO_SYNC.md; module lives in the jouma repo) with a create_from_offline_shift entry point booking a shift/cash-session record, including an over/short accounting entry.
3. Enqueue a shift.push outbox entry in closeShift carrying uuid, device_id, cashier_id, business_date, opening float, movements, counted, expected, variance, and per-method totals (the ShiftSummary already computes these, shift_store.dart:72-112).
4. Register the shift.push sender in lib/core/sync/odoo_wiring.dart beside the order sender; enqueue AFTER the order flush so FIFO guarantees all referenced sales are booked first; ack marks the shift synced.
5. Tests: outbox ordering (orders drain before the shift record), sender status taxonomy mirroring test/core/odoo_sender_test.dart, a staging test asserting the shift record exists in Odoo keyed by uuid.
6. Update docs/ODOO_SYNC.md queue kinds (currently lists only order.push/audit.push/device.status).

**Do it better than Dishflow:** Idempotent by shift uuid, unlike Dishflow's session_adjustments which are bare add() calls that duplicate on retry; and the record is ack-gated instead of fire-and-forget into a world-writable collection.


## P2

### [-] audit.push and device.status have no server sink (fleet heartbeat + remote audit)  `NOT DOING`

**Decision: not doing it, because it would need a new server endpoint.** Both kinds are
registered as local acks in `lib/core/sync/odoo_wiring.dart` and stay that way; the local
audit log remains the record of who did what, and till health is read on the device's own
support screen. Unlike the items below there is no cheaper route: Odoo has no standard
model shaped like an append-only till audit trail or a device heartbeat, so this is a
module change or nothing.

**Dishflow has:** Central audit and health state: order_actions_log and deleted_kitchen_lines collections (firebase_sales_service.dart:700-746), agent_heartbeat docs refreshed every 5s that other devices discover agents from (agent_discovery_service.dart:10-18), and admin dashboards that see till activity.

**offlinePOS today:** The client side is complete and tested: sync_service.dart:143-163 queues unsynced audit rows as audit.push and a device.status heartbeat that replaces by device id; device_status.dart carries pending/dead/oldest-age/needs_attention; heartbeat semantics proven in test/core/heartbeat_test.dart. But /home/username/workspace/offlinePOS/lib/core/sync/odoo_wiring.dart registers both as local no-op acks (_outbox.register('audit.push', (_) async {}); same for device.status) with an explicit comment that a dedicated endpoint is the follow-up. Nothing ever reaches a server; the local audit_log is the only record and no one can see till health remotely.

**Plan steps, kept for whoever revisits the decision:**
1. Add two endpoints to the pos_offline_sync module: batch audit ingest (append-only, idempotent by audit-<id> key) and device status upsert (one row per device_id).
2. Replace the no-op senders in lib/core/sync/odoo_wiring.dart with real senders using the same error taxonomy as the order sender (TransientSyncError/PermanentSyncError).
3. Keep the local audit log as the system of record; server copy is a mirror (audit_log.dart markSynced behaviour already correct, no deletion on ack).
4. Update test/sync/odoo_wiring_test.dart (currently asserts audit drains locally and is never posted as a sale order) to assert the new sink is used, and add sender contract tests.
5. Odoo side: a device-status list view with a needs_attention filter so support sees a till with dead-lettered sales or a >24h outage without walking to it.

**Do it better than Dishflow:** Dishflow's audit collections are world-writable and its agent heartbeats carry LAN IPs into a public database; here audit and health go through the authenticated sync channel only.

### [-] Intraday admin/back-office visibility of live sales  `NOT DOING`

**Decision: not doing it, because it conflicts with a product rule.** Orders push as one
batch at shift close, on purpose: the shop runs on a single shared Odoo login (a licence
limit, not an oversight), and booking the day in one settlement is how the books are meant
to be written. A push-as-rung mode would trade that away for a dashboard. Cloud admin
belongs in Odoo, on the documents the close produces, and the till's own reports already
answer the intraday question for the person standing at it.

**Dishflow has:** Managers see sales in near-realtime without being on site: sales docs land in Firestore within ~60s via AutoSyncService (auto_sync_service.dart:57), flash report and home dashboard use live .snapshots() (flash_report_screen.dart:210,231), the RM web portal (reports.code-solution.org) and rm_mobile_app read the same project, and dashboard_stats/counters aggregate.

**offlinePOS today:** By design the 20s loop is read-only and NEVER drains the outbox (/home/username/workspace/offlinePOS/lib/core/sync/sync_service.dart:112-116,169-201, enforced by test/core/sync_service_test.dart 'refresh never drains'); orders reach Odoo only at shift close (pos_app.dart:1350-1368) or manual Support > Sync now (diagnostics_screen.dart:75). Between closes the back office sees zero sales, and the heartbeat that would at least show till health is unsent (previous item). docs/ODOO_SYNC.md lines 27-44 document this cadence as intentional.

**Plan steps, kept for whoever revisits the decision:**
1. Add an opt-in 'push as rung' mode: a SettingsStore flag that lets the periodic tick also drain the order.push kind, keeping every offline-first guarantee (sale never waits, outbox unchanged, ack-gated); the shift-close default stays per docs/ODOO_SYNC.md.
2. Restrict the periodic drain to order.push only so audit/heartbeat cadence stays unchanged, and reuse the existing online probe so an offline till just skips.
3. No new reporting layer needed server-side: staging_orderpush_test.dart already proves booked orders are confirmed sale.orders visible to standard Odoo sales reports; add an Odoo dashboard combining sales with the device-status model.
4. Tests in test/core/sync_service_test.dart: flag on drains on tick, flag off preserves the current 'refresh never drains' invariant as default.
5. Update docs/ODOO_SYNC.md cadence section to document both modes and when to choose which.

**Do it better than Dishflow:** Visibility is scoped by Odoo auth and record rules instead of Dishflow's world-readable Firestore, and the numbers come from confirmed accounting documents rather than client-computed dashboard_stats with no server authority.

### [-] Staff roster and permission distribution from the server  `NOT DOING`

**Decision: not doing it, because it would need a new server endpoint.** A roster carrying
Argon2id PIN material is not a standard Odoo model, so distributing it means a module
change. Staff are managed on the till (`lib/features/admin/roster_screen.dart`), which is
where a shop manager already works. If it is ever wanted, the cheaper route is a read of
standard models through the generic `call_kw` path the till already uses (`hr.employee` for
names and active flags), with the PIN still set on the device, which needs no module
change. That would be a fresh decision, not something to assume from this note.

**Dishflow has:** pos_users/{odooUserId} is the central credential+authz store with a realtime per-user listener so a permission change propagates to the till live (firebase_permission_service.dart:1223); roles collection; quick-login PIN material stored centrally (quick_login_service.dart:183-189).

**offlinePOS today:** Local auth is strong and complete (Argon2id PIN, persisted escalating lockout, manager-PIN elevation, role permission sets: lib/core/auth/*), and roster management exists on-till (lib/features/admin/roster_screen.dart). But there is no server distribution: UserStore.replaceAll (/home/username/workspace/offlinePOS/lib/core/auth/user_store.dart:38) has zero callers in lib/ (grep confirms all other replaceAll hits are String.replaceAll), and odoo_puller.dart pulls no users/roster model. A cashier hired at head office must be typed into every till by hand; a fired cashier keeps working until each till is edited.

**Plan steps, kept for whoever revisits the decision:**
1. Define a roster source in the pos_offline_sync module: cashier id, display name, role, active flag, and Argon2id PIN hash+salt computed where the PIN is set (the PIN itself never transits).
2. Extend lib/core/sync/odoo_puller.dart to pull the roster alongside the catalogue, guarded like CataloguePull.isUsable so an empty or failed pull never wipes a working roster.
3. Wire the pull into UserStore.replaceAll during SyncService refresh; define precedence (server wins for server-managed accounts, till-local accounts like the bootstrap manager untouched).
4. Preserve lockout state across roster refreshes (auth_attempts is keyed per cashier and must survive, mirroring test/db/auth_attempts_test.dart).
5. Tests mirroring test/db/catalogue_test.dart: failed refresh keeps old roster, deactivated cashier can no longer unlock, hash round-trip verifies against pin_hasher.dart.
6. Docs: ODOO_SYNC.md roster section; note in SECURITY.md that PIN hashes, never passwords, are distributed.

**Do it better than Dishflow:** Dishflow stores AES-encrypted Odoo passwords in a world-readable collection with a hard-coded key (SECURITY_REVIEW H1). Distributing only Argon2id hashes over the authenticated channel closes that class entirely.

### [-] Central till configuration distribution  `NOT DOING`

**Decision: not doing it, because it would need a new server endpoint.** A versioned
till-config document is a new model with a new read call. Settings stay per device
(`lib/core/db/settings_store.dart`), which is also where the hardware-local half of them
has to live anyway. A shop with several tills configures each once, at installation, and
the cost of that is accepted: it is paid at setup, whereas a bad central config push is
paid during service on every till at once.

**Dishflow has:** settings/app_config with 5+ realtime listeners (local_storage_service.dart:1121-1280), settings/print_routing + pos_terminals for terminal-to-printer routing (print_routing_service.dart:9-12,52-80), payment_methods, branches: change once centrally, every till updates live.

**offlinePOS today:** A rich settings layer exists but is 100% per-device: /home/username/workspace/offlinePOS/lib/core/db/settings_store.dart (437 lines: receipt toggles, category colours, kitchen station routing 154-292, tax matrix per category x order type, favourites, language). No pull path exists (grep app_settings/settings in odoo_puller.dart and sync_service.dart: nothing). A 5-till shop must have its tax matrix and station routing configured 5 times, and drift between tills is undetectable.

**Plan steps, kept for whoever revisits the decision:**
1. Add a versioned till-config document server-side in pos_offline_sync, keyed by OFFLINE_TILL_ID (or a shop-wide default plus per-till overrides).
2. Pull it during SyncService refresh and apply through an explicit allowlist of SettingsStore keys; hardware-local keys (printer names, resolved hosts) are excluded by construction.
3. Conflict rule: server config applies only when its version increases; a local manual change is kept and audited so a manager override on-site survives until head office bumps the version.
4. Tests: allowlisted keys applied, empty pull never wipes, excluded keys untouched, version gate respected.
5. Docs: ODOO_SYNC.md config section; docs/WINDOWS_TEST.md note that local settings edits remain possible offline.

**Do it better than Dishflow:** Allowlisted, versioned config instead of Dishflow's ad-hoc listeners on a world-writable doc; a bad config push is diffable and revertible by version rather than instantly live everywhere.

### [x] Sync-path certificate pinning  `done` / [-] device-token enrolment  `NOT DOING`

Two halves, decided separately.

**Pinning is built:** `011a8fe` adds a pinned transport for every Odoo call
(`lib/core/sync/http_post.dart`, pins from `SYNC_CERT_PINS` in
`lib/core/config/till_config.dart`), and `3798cdd` moves the check into the TLS handshake so
it happens **before the request body is written**, because that body is the shared login on
authenticate and the day's takings on a close. The client trusts no roots and accepts the
leaf on its digest, so pinning replaces chain validation: an operator-installed CA cannot
mint a certificate this till will talk to, and an expired pinned certificate is still
accepted, which is why rotation ships two pins. No pins configured means today's platform
trust, deliberately, because a pin invented for a shop that was never given one is a till
that can never bank its day. Tests: `test/sync/pinned_sync_transport_test.dart`.

**Device-token enrolment: not doing it, because it would need a new server endpoint.**
Issuing and revoking per-device tokens is a module change with no standard-model
equivalent, so `lib/core/auth/device_token.dart` stays written, tested and unwired, and the
till keeps authenticating as the shared integration login. docs/SECURITY.md carries this as
an open item with the reason rather than as a silent gap.

**Dishflow has:** Effectively nothing better (anonymous Firebase auth rolling out over world-open rules, firebase_identity_service.dart; print agents authenticate with a public API key), so Dishflow is worse here. But offlinePOS's own documented layer-1 auth (signed time-boxed device token, ARCHITECTURE.md lines 69-81) is the parity+ target.

**offlinePOS today:** DeviceToken is a complete but dead class: /home/username/workspace/offlinePOS/lib/core/auth/device_token.dart is referenced only by test/core/device_token_test.dart (grep). The till authenticates as the shared integration login whose password sits in the SQLCipher odoo_endpoint table (schema.dart v7, comment says single-operator local test only; server_settings_screen.dart:77-86 shows the amber warning). Cert pinning existed only on the update channel (lib/core/updates/update_transport.dart) and lib/core/sync/http_post.dart had none, which is the half that is now built. SECURITY.md open checklist items: backend deny-by-default/tenant-scoped, secret rotation.

**Plan steps, kept for whoever revisits the enrolment decision:**
1. Add an enrolment exchange to pos_offline_sync: one-time enrolment code entered on the till returns a server-signed DeviceToken (Ed25519 verification already available via the cryptography dependency and the manifest_signature.dart pattern).
2. Wire DeviceToken into lib/core/sync/odoo_sender.dart auth (token header validated by the module) and stop persisting the Odoo password; keep the password path behind an explicit local-test flag only.
3. Add certificate pinning to lib/core/sync/http_post.dart reusing the PinnedUpdateTransport pattern, pins supplied via till_config.dart dart-defines like the update channel. **Done** (`011a8fe`, `3798cdd`).
4. Implement renewal: renew 7 days early during refresh, grace period longer than the worst expected outage per ARCHITECTURE.md, so an offline till never locks itself out.
5. Tests: token expiry/renewal, revoked device rejected server-side, pinned transport refuses a wrong cert, unlockable-while-offline invariant.
6. Update SECURITY.md checklist and ARCHITECTURE.md auth section from 'documented intent' to implemented.

**Do it better than Dishflow:** Per-device revocable identity is something Dishflow has no equivalent of at all: anyone holding its bundle can read and write any tenant's entire operational data.

### [-] Customer records: no push to Odoo, no partner_id backfill  `NOT DOING`

**Decision: not doing it, because it would need a new server endpoint.** A match-or-create
that returns the partner id is a new call, and without it there is nothing to backfill, so
walk-ins keep going out as name and phone for the server to match at booking and
`local_customers` stays till-local. If it is ever wanted, the cheaper route is `res.partner`
through the generic `call_kw` path the till already uses (search plus create, reading the id
straight back), which needs no module change. That would be a fresh decision, not something
to assume from this note.

**Dishflow has:** customers and delivery_customers collections shared across all devices in realtime; any till sees a customer captured on another till instantly; delivery board reads customer/driver fields off sales docs.

**offlinePOS today:** Pull exists but capped: odoo_puller.dart:82 pulls res.partner customer_rank>0 LIMIT 500, full replace each time. Local capture exists but is till-local: local_customers with synthetic negative ids (/home/username/workspace/offlinePOS/lib/core/db/customer_store.dart). On sale, order.dart:354-357 nulls the negative partner_id and ships name/phone so the server can match-or-create, but nothing backfills the created partner_id into local_customers (the v10 partner_id link column exists and is never written by sync), so the same walk-in becomes a new partner on every visit and a customer captured on till A does not exist on till B.

**Plan steps, kept for whoever revisits the decision:**
1. Add a customer.push outbox kind keyed on the local customer uuid; pos_offline_sync endpoint does match-or-create on res.partner and returns the partner id.
2. On ack, write partner_id back into local_customers so subsequent orders carry the real id instead of name/phone matching.
3. Make the partner pull incremental (write_date > last pull, paged) in odoo_puller.dart and remove the 500 hard cap.
4. Replicate local_customers over the LAN fabric so a delivery customer captured on one till is pickable on all tills before the server round-trip.
5. Tests: push/ack backfill, replay idempotent by uuid, incremental pull paging, order payload uses the backfilled partner_id.
6. Docs: ODOO_SYNC.md queue kinds and wire contract.

**Do it better than Dishflow:** Odoo's res.partner becomes the single customer master (deduped, reportable), instead of Dishflow's parallel Firestore customer store that never reconciles with Odoo partners.

### [ ] Cross-till session/day coordination and force close  `NEXT WAVE`

**Now unblocked by the fabric, and worth doing next.** The reason this was `missing` was
that nothing spanned devices; that reason is gone. Shift lifecycle becomes a fourth event
kind on the existing log, the deterministic business-day key already exists in
`lib/domain/business_day.dart`, and the pull-with-cursor behaviour already handles the hard
case (a till that was off during the close learns about it on rejoin). Needs no server side
at all. The plan steps below stand as written.

**Dishflow has:** active_sessions/{connectionId} with transactional open, deterministic timezone-proof session id (active_session_service.dart:93-121,348-420), auto-close of stale sessions, and force-logout fan-out to every device when the session closes (session_status_watcher.dart:57-59, _ForceLogoutGate in main.dart:518-609); cashier_shifts isLocked prevents concurrent use.

**offlinePOS today:** Each till has exactly one open local shift (shift_store.dart enforces it) and lib/domain/business_day.dart provides a deterministic shared day key (04:00 cutover), but no concept spans devices: no session watcher, no force close/logout, nothing stops till B ringing sales into a business day the manager already closed on till A. Grep for any session-coordination code in lib/ finds none (consistent with zero inbound sockets).

**Plan steps:**
1. On the LAN fabric, add shift lifecycle events (opened/closed) carrying business_date, device_id, cashier_id.
2. Reuse business_day.dart's deterministic key as the fleet session key, mirroring Dishflow's composeSessionId trick so clock/timezone skew cannot split a day.
3. Implement a configurable day-close policy: manager Z-close on one till warns, blocks new orders, or auto-closes shifts on the others; each till still closes its own drawer count locally.
4. Handle the offline till: on rejoin it learns the day closed, prompts its own close, and its late orders keep their true business_date (already derived per order).
5. Tests: two-till close propagation, offline-till rejoin reconciliation, no sale ever blocked by fabric unavailability (degrade to today's independent behaviour).
6. Docs: ARCHITECTURE.md and ODOO_SYNC.md day-close semantics.

**Do it better than Dishflow:** Coordination keeps working on a dead internet connection (Dishflow's force-logout requires Firestore), and a till that missed the close self-reconciles instead of silently selling into a closed day.


## P3

### [-] Attendance capture is local-only (no server sync)  `NOT DOING`

**Decision: not doing it, because it would need a new server endpoint** as planned (a module
entry point booking `hr.attendance`, plus the roster mapping above, which is itself not being
done). Clock in and out stay on the till in `lib/core/db/attendance_store.dart`. If it is
ever wanted, the cheaper route is writing `hr.attendance` directly through the generic
`call_kw` path the till already uses, which needs no module change; it does still need a
cashier-to-employee mapping. That would be a fresh decision, not something to assume from
this note.

**Dishflow has:** attendance, manager_attendance, and fingerprint_templates collections in Firestore (firebase_attendance_service.dart:17-47) plus a ZKTeco fingerprint agent; HR sees clock in/out centrally.

**offlinePOS today:** Clock in/out exists and persists locally: attendance table (schema.dart v11) + /home/username/workspace/offlinePOS/lib/core/db/attendance_store.dart. But grep for attendance across lib/core/sync/*.dart returns nothing: records never leave the till, so payroll/HR has no access without physically reading the device.

**Plan steps, kept for whoever revisits the decision:**
1. Add an attendance.push outbox kind (keyed attendance-<id> like audit) enqueued on clock in/out.
2. Map cashiers to employees via the roster distribution item, then book into hr.attendance through a pos_offline_sync endpoint.
3. Register the sender in odoo_wiring.dart with the standard error taxonomy; ack marks rows synced (add a synced_at column, schema v14 additive).
4. Tests: enqueue on clock events, idempotent replay, FIFO alongside order.push.
5. Docs: ODOO_SYNC.md queue kinds.

**Do it better than Dishflow:** hr.attendance feeds real payroll instead of Dishflow's raw Firestore rows; and skip the fingerprint-template-in-cloud pattern entirely (Dishflow stores biometric templates base64 in a world-readable collection).

### [-] Stock and inventory management  `OUT OF SCOPE` / [ ] shop-wide 86 board  `NEXT WAVE`

Two halves again.

**Stock and inventory management are out of scope for the offline till, by prior
decision.** Quantities, availability and any local stock ledger stay in Odoo, which the
booking chain already keeps authoritative by validating a delivery per sale. The till does
not pull `qty_available` and does not decide whether something can be sold.

**The shop-wide 86 board is next wave, now unblocked by the fabric.** It is a per-till
setting today (`lib/core/db/settings_store.dart`), and making it shop-wide is a fifth event
kind on the existing log with no server involvement. Worth doing: a run-out item that is
still sellable on the other till is the kind of thing a kitchen notices immediately.

**Dishflow has:** pos_stock and warehouse_cache collections cache inventory in Firestore; product availability decisions can consult them; expenses_cache similar.

**offlinePOS today:** No stock quantity exists anywhere on the till: odoo_puller.dart pulls only display_name/lst_price/pos_categ_ids/barcode/to_weight/taxes_id for products (lines 14-91), never qty_available. The 86 (sold-out) board is a per-till local setting (/home/username/workspace/offlinePOS/lib/core/db/settings_store.dart:300, comment says 'on this till'), so 86ing a run-out item on one till leaves it sellable on the others.

**Plan steps** (step 3 is the 86 board, the part that is next wave; the rest is the
out-of-scope half, kept for whoever revisits it):
1. Add an optional qty_available field to the product pull in lib/core/sync/odoo_puller.dart, degrading gracefully like the account.tax pull does when the server refuses.
2. Surface low/out badges on the sell screen from the pulled quantity; stock truth stays server-side, since the booking chain already decrements via validated delivery (docs/ODOO_SYNC.md lines 5-24), so no local stock ledger is needed.
3. Replicate 86 toggles over the LAN fabric so sold-out is shop-wide within seconds.
4. Tests: puller degradation, badge thresholds, 86 replication convergence.
5. Docs: note that displayed quantity is advisory (as-of-last-pull), never a sale blocker.

**Do it better than Dishflow:** Because sales book stock.move on sync, Odoo inventory is authoritative without a client-maintained cache that drifts (Dishflow's warehouse_cache has no server reconciliation).

### [-] Pricing/promotions state: pricelists, coupons, gift cards, loyalty  `OUT OF SCOPE`

**Out of scope for the offline till, by prior decision.** Manual per-line and whole-order
discounts are what the till does; pricelists, coupons, gift cards and loyalty stay in Odoo.
A promotion engine on the device is a second place for prices to be decided, and the two
would disagree the first time a rule changed mid-service.

**Dishflow has:** pricelists + product_prices (batched writes, pricelist_service.dart:108,303), discounts collection, coupons/gift cards with realtime listeners (coupon_service.dart:99,239), loyalty_config + loyalty_transactions.

**offlinePOS today:** Only manual discounts exist: per-line discount and whole-order discountFactor in lib/domain/order.dart (folded safely into the wire payload at 345-369). schema.dart v1-13 has no pricelist, coupon, or loyalty table; the catalogue pull carries a single lst_price per product. No promotion can be configured centrally and honoured offline.

**Plan steps, kept for whoever revisits the decision:**
1. Pull pricelist rules applicable to the till's pos.config into new tables (schema v14+, replace-all transaction pattern from catalogue_store.dart) and resolve prices locally at ring time.
2. Coupon/gift-card offline-first flow: pull active coupon codes with the catalogue; validate locally; record redemption as order payload fields so the server settles at booking (a doubly-spent coupon comes back as status rejected, which the existing park path already handles).
3. Loyalty as server-side accrual during create_from_offline_pos; the till shows the balance from the partner pull rather than maintaining its own ledger.
4. Tests: pricelist resolution precedence, coupon redemption replay (same uuid never double-redeems), rejected-coupon park path.
5. Docs: ODOO_SYNC.md payload extension and pull scope.

**Do it better than Dishflow:** Settlement-at-booking makes double-spend impossible across offline tills, which Dishflow's realtime coupon docs cannot guarantee during an outage (two tills can redeem the same coupon while Firestore is unreachable).

### [-] Remote order intake (QR menu / ecommerce / delivery-platform orders)  `OUT OF SCOPE`

**Out of scope for the offline till, by prior decision.** Orders exist when they are rung on
the till. Intake channels are inherently online, so they belong on the Odoo side of the
boundary; nothing about them may end up on the critical path of a sale.

**Dishflow has:** menu_orders and ecommerce_orders collections with public create, transactional cashier claim on receivedBy (firebase_menu_service.dart:191-215), realtime pending-order watch, daily transactional order counters, and a documented ecommerce status contract (docs/ECOMMERCE_DELIVERY_INTEGRATION.md).

**offlinePOS today:** No intake channel of any kind: grep for menu/ecommerce/intake across /home/username/workspace/offlinePOS/lib/ finds nothing relevant; orders exist only when rung on the till. Remote intake inherently requires internet, but the architecture has no pull path for it even when online.

**Plan steps, kept for whoever revisits the decision:**
1. Keep intake server-side: remote orders land in Odoo (website sale or a custom pending-order model in pos_offline_sync), never pushed to the till, so nothing at sale time depends on the cloud.
2. Add an inbound fetch to SyncService.refresh(): pull unclaimed remote orders for this till's pos.config; claim atomically server-side by writing claimed_by=device_id (the server transaction replaces Dishflow's Firestore claim).
3. Materialise a claimed order as a local held order (map the wire shape into Order.fromMap-compatible payloads) so it flows through the normal pay/kitchen path and syncs back as a booked sale referencing the intake id.
4. Degrade cleanly: offline means no new remote orders (inherent), selling untouched; claimed-but-unpaid orders survive locally like any held order.
5. Tests: claim atomicity (two tills, one winner), claimed order round-trip to booking, offline degradation.
6. Docs: new docs section for the intake contract mirroring Dishflow's ECOMMERCE_DELIVERY_INTEGRATION.md.

**Do it better than Dishflow:** Dishflow's intake collections allow public unauthenticated create/write into the operational DB; an Odoo-side inbox validates and rate-limits at the boundary, and the claim is a real server transaction.

### [x] Core order pipeline to Odoo (sales, payments, discounts, refunds, splits)  `done`

**Dishflow has:** sales collection as operational hub, AutoSync every 60s to Firestore, human-triggered Odoo push at session close via custom addon /api/sale/order/create with clientOrderRef timeout recovery (odoo_api_service.dart:2084-2233), syncedToOdoo flip, pending-counter recovery from Firestore.

**offlinePOS today:** The equivalent exists and is stronger where it matters: real sender to sale.order.create_from_offline_pos (/home/username/workspace/offlinePOS/lib/core/sync/odoo_sender.dart:55-63) booking the full sale->delivery->invoice->payment chain; idempotency by client uuid with UNIQUE(kind,payload_uuid) upsert (sqlite_outbox_store.dart:13-27); created/duplicate/rejected taxonomy with park-not-block (outbox.dart); refunds pushed as durable orders (pos_app.dart:785-793); split payments and split checks sync as independent orders (pos_session.dart:340-361,518-556); crash-window reconcile (reconcilePending, main.dart:135-141); double-discount guard on the wire (order.dart:345-369); proven end-to-end by test/staging/staging_orderpush_test.dart (confirmed sale.order keyed by offline_uuid, state='sale'). The one rough edge left, a failed shift-close flush with no timed retry, is now closed.

**Plan steps:**
1. Add a bounded timed retry after a failed shift-close flush. **Done** (`9da8cb3`, `lib/core/sync/sync_service.dart`): armed only by a batch push that ends with sales still queued, one attempt per 5 minutes on the existing loop, given up after 12 hours measured from the first failure, skipped while offline or while another push owns the queue, and armed in memory only so a restart hands the job back to the next close or a manual sync. Bounds and reasoning in docs/ODOO_SYNC.md; tests in `test/core/sync_service_test.dart`.
2. Consider server-side batch submission (module accepts the payload list it already receives as [[payload]]) to cut per-order HTTP round-trips on a week-long backlog; local pacing already exists (batch 20, maxBatches 1000). Still open, and note it needs **no** module change, so it stays available if a long catch-up is ever measured as too slow.
3. Keep everything else as-is; extend only via new outbox kinds per the other gap items.

**Do it better than Dishflow:** Already beyond Dishflow: ack-gated idempotent booking into real accounting documents versus a world-writable cloud mirror plus manually triggered per-order pushes; encrypted at rest; replay-safe across schema upgrades (test/db/store_test.dart).


---

# DETAILED FINDINGS: offlinePOS — Current-State Inventory (branch `main`, HEAD `8df1d1d` "sell: keep the tip on a split-share payment out of the balance", 136 commits)

# offlinePOS — Current-State Inventory (branch `main`, HEAD `8df1d1d` "sell: keep the tip on a split-share payment out of the balance", 136 commits)

Repo: `/home/username/workspace/offlinePOS` (Flutter, `offline_pos`, app id `eg.codesolution.offline_pos`). ~21,000 lines under `lib/`, 510 unit/widget tests under `test/`. The README's "Not built yet" section (`README.md:35-39`) is fully stale: encrypted SQLite (SQLCipher), Argon2id hashing, the Odoo sender, ESC/POS printing and the full UI are ALL implemented and tested. `docs/ARCHITECTURE.md:56-62` ("Encryption at rest is not implemented") is also stale; `docs/SECURITY.md:83-85` checklist and `test/db/encryption_test.dart` show SQLCipher encryption is done and proven. Trust the code.

Other local branches/worktrees: `feat/printing` and `feat/shifts` (both at `07278ab`, behind main, checked out under `.claude/worktrees/`), two throwaway agent worktrees. `.shots/` holds 31 UI screenshots (login, sell, floor, reports, settings, KDS etc.). `.jez/reviews` exists (review artefacts).

---

## 1. lib/app — app shell, session, till lifecycle

### `lib/app/main.dart` wait — actual entry is `lib/main.dart` (243 lines) — IMPLEMENTED
Composition root. Opens SQLCipher DB at `getApplicationSupportDirectory()/pos.db` with a 32-byte raw-hex key from `DbKey(SecureKeyStore())` (platform keychain / Windows credential store; key loss = deliberate data loss, documented). Builds all stores, `Outbox` (starts with NO senders — accumulate-only until an endpoint is configured), `AuthService` with `Argon2idPinHasher` and on-disk attempt store, `BootstrapCashier.ensure` (random per-launch 6-digit provisioning PIN, manager role, id `setup`), `OdooWiring` (onOrderBooked→`orders.markSynced`, onOrderRejected→audit `order.rejected`), unauthenticated reachability probe (`/web/webclient/version_info`, 6s timeout), `SyncService(...).start()` (20s timer, read-only), `PrinterRegistry.fromMap` persisted via `PrinterStore`, `TillActivity`, optional env-default Odoo endpoint (`ODOO_URL/ODOO_DB/ODOO_LOGIN/ODOO_PASSWORD` dart-defines; a device-saved endpoint wins), and `_updateService(...)` which is null unless `UPDATE_MANIFEST_URL` + `UPDATE_PUBLIC_KEY` + `UPDATE_CERT_PINS` are ALL set (no partial update channel). `APP_VERSION` dart-define (default `0.0.0-dev`). NOTE: `UpdateService` is built WITHOUT an `installer` callback, so updates can be checked/downloaded/verified/staged but never executed (see §2 updates).

### `lib/app/pos_app.dart` (1406 lines) — IMPLEMENTED
The app shell (`PosApp`): MaterialApp with en/ar locales + RTL via `LocaleController`, teal Material 3 touch-tuned theme. Holds `PosSession?`; `LoginScreen` when signed out, `SellScreen` in a Stack (+ first-sale `WizardOverlay`) when signed in. Key behaviours, all wired:
- 30s background timer `_catchUp()`: fires due course-timed kitchen lines (`_fireDueTimedLines` across current + held + awaitingSync orders), flushes the receipt spool, then `updates?.check()`.
- Sign-in lands on the floor plan (`_openFloor`) unless a draft was crash-restored; sign-out via drawer/end-shift resets session + `sync.cashierId`.
- `_receiptPrinter`: `SpooledPrinter(RegistryPrinter(printers,'receipt'), spool: SqlitePrintJobStore)`; dropped jobs audited (`receipt.dropped`).
- `_printReceipt`: on-device receipt settings win over `TillConfig` build defaults; cash detection opens drawer only on first copy of a non-reprint when `openDrawerOnSale`; N copies (1-3) with per-copy spool references; broad catch audits `receipt.failed`.
- `_printDeletion`: void/cancel record slips ("ITEM VOIDED"/"ORDER CANCELLED"), spooled.
- Kitchen: `_fireKitchen` routes lines per station via `routeToStations` (product override > category stations > default 'kitchen'), per-station idempotency via `line.firedStations`, marks `printedToKitchen` only when every routed station got a copy, falls back to the receipt printer when a station is unreachable (spool counts as delivered), `_fireVoid` sends CANCEL slips to the stations that actually printed the line, `_sendToStation` distinguishes lost-outright (retry later) from spooled.
- Drawer nav (all wired): Tables (floor), Open orders, Order history, Kitchen display, Reports (permission-gated `viewReports`), Shift/cash-up, Attendance, No sale (open drawer, `openDrawer` permission, immediate-or-nothing `sendNow`, audited), manager-only Staff + Audit log, Settings hub, Support & printers.
- Permission machinery: `_authorize(Permission, ctx)` = role allows → pass; else manager-PIN dialog (`auth.authorizeManager`); denial audited `permission.denied`. `_authorizeManager` for non-delegable actions (Roles & permissions screen).
- Settings hub entries (grouped): Language toggle en/ar, Shop & receipt (gated openSettings), Receipt designer (gated, with sample test print), Printers & kitchen routing (gated managePrinters, per-printer test print with no fallback), Category colours, Grid density (0/2-6 tiles), Customers, Quick notes, Discounts (gated openSettings), Server (Odoo) (gated), Staff (gated manageStaff), Roles & permissions (manager-only).
- Refund flow (permission `refund`): `RefundScreen` push, refund saved+enqueued (`order.push`)+audited+printed.
- Shift close: cash method ids from catalogue payment methods, `authorizeClose` gate BEFORE close, `onCloseSync` = reconcile → count → `sync.flush()` → honest message (synced N / offline, saved on till).
- `_printShiftReport` X/Z to receipt printer (spooled). `_sampleOrder()` for test prints.
- Floor occupancy (`_floorOccupancy`) shared between floor home and pick-table so both colour identically; occupied = held orders + on-screen order; takeaway/delivery start buttons on floor home via `session.startFresh`.

### `lib/app/pos_session.dart` (624 lines) — IMPLEMENTED
Live selling state, deliberately synchronous, every mutation persisted immediately via `OrderStore.save`. Covers: crash restore (`current` restores first draft on disk); `addProduct` with modifier price capture and smart line consolidation (`_mergeableLineFor` refuses to merge fired/timed/noted/discounted/seat-tagged lines or metadata-drifted products, `_sameModifiers` full-field compare); removeLine/voidLine(reason, audited)/setQuantity/setLineDiscount/setLineNote/clear; whole-order discount with reason; order types with delivery-detail cleanup; guests/table/note/deliveryCost/tip/delivery customer/Odoo customer; hold/recall/newOrder/startFresh (empty-draft deletion so no orphan drafts); `pay()` (save→enqueue order.push→audit→fresh order); `payShare()` (even-split/partial payment with running balance, tip additive to total, finalizes when balance ≤ 0.001); course firing (`setLineFireDelay`, `setOrderFireDelay`); seats (`setLineSeat` peels 1 unit off a multi-unit line); `splitOffQuantity` (peel N whole units; fractional/weighed lines all-or-nothing); `splitLineToUnits`; `payCheck` (split bill: carve lines into their own paid order; order-level % discount rides along; deletes source when emptied); move/merge across tables with discount-flattening so nothing is double-discounted (`_carryOrderDiscount`/`_flattenOrderDiscount`), all audited (`order.moved`, `order.merged`).

### `lib/app/till_activity.dart` (12 lines) — IMPLEMENTED (tiny by design)
`TillActivity.saleInProgress` mutable bool; the seam between the sell screen and the update gate.

---

## 2. lib/core

### core/audit — IMPLEMENTED
`audit_log.dart`: append-only `audit_log` table; `record(actor,event,detail)`, `unsynced()/markSynced()` for outbox handoff, `recent()` with event/time filters (backs Audit-log screen + activity report), `events()` for dropdown.

### core/auth — IMPLEMENTED (device token is a dormant model)
- `pin_policy.dart`: `PinPolicy` (4-6 digits, 5 attempts, 5-min lockout doubling to 2h cap), `AttemptStore` interface, `MemoryAttemptStore` (tests only), `PinAttemptGuard` (per-cashier, lockout expiry clears count).
- `pin_hasher.dart`: `PinHasher` interface + `Argon2idPinHasher` (package `cryptography`, 19 MiB / 2 iters / OWASP baseline, constant-time verify, malformed stored hash → false).
- `auth_service.dart`: local-only unlock (sealed `AuthOk/AuthRejected/AuthLockedOut/AuthMalformed`), unknown user indistinguishable from wrong PIN, per-cashier lockout with true remaining time, everything audited (`pin.unlock/pin.rejected/pin.locked_out/sign_out`); `authorizeManager(pin)` checks any active manager (audited both ways); `enrol()` hashes locally.
- `user_store.dart`: `users` table, upsert/replaceAll(transactional)/active/all/byId; `Cashier.isManager` = role=='manager'.
- `bootstrap_cashier.dart`: random 6-digit provisioning PIN, per launch, manager role, `setup` id reserved; ends once a real roster exists.
- `permissions.dart`: 12-value `Permission` enum with stable disk keys (applyDiscount, voidLine, cancelOrder, refund, reprint, openDrawer, priceOverride, closeShift, manageStaff, managePrinters, openSettings, viewReports).
- `device_token.dart`: **MODEL ONLY / NOT WIRED** — `DeviceToken` (signed, time-boxed, grace-period renew) has serialization + validity logic and a test, but no enrolment flow, no signature verification code, and nothing in `main.dart` uses it. The `device_enrolment` table (schema v3) exists as a cache slot; `DeviceStore` only uses the key-value table for `device_id`. Classify: stub for the fleet/enrolment story described in ARCHITECTURE.md/SECURITY.md.

### core/config — IMPLEMENTED
`till_config.dart`: all build-time `--dart-define`s (SHOP_NAME, SHOP_TAX_ID, RECEIPT_FOOTER, UPDATE_MANIFEST_URL, UPDATE_PUBLIC_KEY, UPDATE_CERT_PINS, SOLE_TILL default true). `hasUpdateChannel` requires the complete triple; `updateVerifier` throws on non-Ed25519 key at first launch.

### core/db — IMPLEMENTED, encrypted
- `database.dart`: `Db.open(path, encryptionKey)` — SQLCipher `PRAGMA key` first (raw 64-hex → `x'..'` form, else passphrase), key proven by reading sqlite_master before migrating, WAL, FK on, transactional stepwise migrations.
- `schema.dart`: version 13. v1 orders/outbox(unique (kind,payload_uuid), pending index)/audit_log; v2 catalogue (categories, products with barcode+sold_by_weight+tax_rate, modifier_groups, modifiers, product_modifier_groups, catalogue_meta); v3 users + device_enrolment; v4 outbox dead-lettering; v5 printers(by name)+wizard_dismissals; v6 print_jobs (durable spool) + auth_attempts; v7 odoo_endpoint (single row, password stored for local test only); v8 shifts; v9 pos_tables + app_settings KV; v10 local_customers; v11 attendance; v12 pos_tables.shape; v13 divider vertical+span.
- `db_key.dart` + `secure_key_store.dart`: 32-byte random key generated once, held in `flutter_secure_storage` (`offlinepos_db_key_v1`); lost keychain = unreadable DB by design.
- Stores (all implemented): `order_store.dart` (payload-JSON single-writer model; drafts/held/awaitingSync/recent/kitchenTickets/setKitchenStatus/markSynced; delete only for draft/held), `sqlite_outbox_store.dart` (upsert-on-(kind,uuid), pending/markSent/markFailed/markDead/dead/revive/pruneSent(7d)/oldestPendingAge & pendingCount excluding heartbeat, pendingSalesCount), `catalogue_store.dart` (transactional replaceAll incl. payment methods+customers in catalogue_meta JSON, staleness, products search/barcode/byId, modifierGroupsFor single indexed join), `settings_store.dart` (KV bag: shop identity, receipt designer toggles incl. divider style/columns 42-32/copies/openDrawerOnSale, quick comments, discount reasons+presets+cap, category colours, category/product→stations multi-station routing + renameStation, language, 86'd products, favourites, grid columns, role-permissions map with cashier defaults {reprint, viewReports}, manager immutable-full), `shift_store.dart` (openShift refuses second open, movements JSON with paid-out categories, closeShift, X/Z `summary` window over paid+synced orders with cash-vs-card split; empty payments = implicit cash), `table_store.dart` (floor plan CRUD, unique names, next-free-cell placement, sections, divider geometry), `attempt_store.dart` (durable PIN attempts), `attendance_store.dart` (clock in/out, multiple staff concurrently), `customer_store.dart` (local customers, negative synthetic ids so they never collide with Odoo partner ids), `device_store.dart` (persistent per-device uuid), `print_job_store.dart` (durable spool per printer name), `printer_store.dart` (printers table persistence for the registry).

### core/i18n — IMPLEMENTED
`l10n.dart` (606 lines): English-string-as-key `tr(context, en)`, ~426 Arabic translations (commit `1136a33` filled gaps), graceful fallback to English, `LocaleController` persisting 'en'/'ar' via SettingsStore, RTL free via Material delegates. Languages: English + Arabic only.

### core/onboarding — PARTIAL (machinery done, only 1 of 5 wizards wired)
`wizard_id.dart`: 5 wizards defined (firstSignIn, firstSale, modifiers, diagnostics, printerSetup) with frozen disk keys. `wizard_store.dart`: per-cashier per-wizard dismissals, later-shipped wizard still shows once, reset per cashier. Only `WizardId.firstSale` is actually shown (pos_app.dart:256/399); the other four ids have no UI call sites yet.

### core/printing — IMPLEMENTED (network ESC/POS; USB/Bluetooth NOT wired)
- `escpos.dart`: dependency-free ESC/POS builder; Windows-1252 code page declared to printer (`ESC t`), never throws on unmappable chars ('?'), row/rule/centred column maths, bold/size/align, cut, drawer kick (`ESC p`).
- `receipt_builder.dart`: customer receipt from settings toggles (order type, table+covers, datetime/number, cashier, customer, per-line modifiers + line-discount lines, subtotal/discount(+reason)/delivery/tip breakdown, tax-inclusive Net/Tax lines, TOTAL double-height, tender lines, cash received/change incl. legacy fallback, footer, REPRINT/REFUND banners, divider styles, optional drawer kick before cut) + `buildDeletion` (void/cancel slip, nets order discount, never kicks drawer). Reference = uuid tail (`#ABC123`).
- `kitchen_ticket.dart`: KOT builder (no prices, double-height names, bold notes, order-type/table/guests header, station header, `buildVoid` CANCEL slip) + `routeToStations` (product override > category stations > 'kitchen' fallback, multi-station fan-out).
- `printer_transport.dart`: `TcpPrinter` (TCP 9100, 5s fail-fast, 1 retry for wifi roaming, socket always destroyed), `FallbackPrinter`, `SpooledPrinter` (durable spool, cap 100 with audited drops, ordered flush, `sendNow` for drawer kicks).
- `printer_discovery.dart`: bounded concurrent /24 subnet sweep (300ms probes, 32 in flight, optional budget, never throws).
- `printer_registry.dart`: name-first identity, last-known-host-first resolution, reverse-DNS identity learning (500ms hard cap, off the print path), sweep backoff 45s for dead printers, refuses to adopt a stranger when identity mismatches, in-flight resolution dedupe, persistence via toMap/fromMap (corrupt rows skipped).
- `registry_printer.dart`: name→address per job. `spool_store.dart`: SpoolStore interface + MemorySpoolStore.
- Not present: USB/Bluetooth/serial printing (docs/WINDOWS_TEST.md:77 states "USB printers are not wired yet").

### core/sync — IMPLEMENTED for local-test topology; fleet backend NOT built
- `outbox.dart`: append-only durable queue, ordered drain in batches of 20 (maxBatches bound), senders registrable at runtime, missing sender = keep pending + record `unhandledKinds`, `PermanentlyRejected` → dead-letter park, transient failure stops drain preserving order, maxAttempts 25 then park.
- `odoo_sender.dart`: JSON-RPC to Odoo: `/web/session/authenticate` (uid + session cookie capture/replay), `orderSender` posts `[payload]` to `sale.order.create_from_offline_pos` via `/web/dataset/call_kw`, overwrites payload `device_id` with `kOfflineTillId` (dart-define `OFFLINE_TILL_ID`, default `till-1`) for pos.config routing; module status handling created/duplicate=ack, rejected=park; error taxonomy: socket/5xx/429/non-JSON(captive portal)/session-expired = transient, 4xx/auth-rejection/Odoo error = permanent. `callKw` for reads.
- `odoo_puller.dart`: catalogue pull — pos.category, product.product (available_in_pos, display_name, lst_price, pos_categ_ids, barcode, to_weight, taxes_id→percent via account.tax, template→variant modifier-group mapping), optional add-on models `product.modifier.category`/`product.modifier` (degrade to none), pos.payment.method (is_cash_count), res.partner customers (limit 500). `CataloguePull.isUsable` refuses empty pulls.
- `odoo_wiring.dart`: runtime configure/disable; registers `order.push` (lazy auth, onOrderBooked→markSynced, onOrderRejected→audit) and **no-op local-ack senders for `audit.push` and `device.status`** (explicit stub: "no server sink yet... a dedicated endpoint is the follow-up"). `catalogueCall` reads through the live sender.
- `sync_service.dart`: 20s timer runs `refresh()` ONLY (probe → online badge; catalogue pull if stale >6h; never drains orders). `tick()`/`flush()` = the batch push (reconcile paid-but-unqueued sales, queue audit + heartbeat, drain, pruneSent, refresh catalogue) — invoked at shift close and Support "Sync now" only. `status()` → `DeviceStatus` heartbeat; `catalogueRevision` notifier reloads the sell grid; `online` ValueNotifier starts false.
- `device_status.dart`: heartbeat payload (pending/dead/unsyncedAudit/oldestPendingAge/catalogue age/lastError/cashier, `needsAttention` = dead>0 or oldest>24h).
- `odoo_endpoint.dart`: single-row endpoint store; password stored on device documented as single-operator local test only (fleet backend with the one credential is design intent, not built).
- `http_post.dart`: dart:io POST with header capture, 20s/30s timeouts.

### core/theme, core/widgets — IMPLEMENTED
`app_colors.dart` shared status palette + stable per-category fallback colours; `feedback.dart` (`showToast` kinds + `EmptyState`); `numeric_keypad.dart` (touch pad + `promptNumber`).

### core/updates — IMPLEMENTED except actual install execution
- `update_manifest.dart`: semver-correct `AppVersion` (1.10>1.9, pre-release ordering, build metadata ignored) + manifest model (version, url, sha256, mandatory flag).
- `manifest_signature.dart`: Ed25519 `ManifestVerifier` over the exact manifest bytes (`{"manifest": b64, "signature": b64}` envelope).
- `update_transport.dart`: `PinnedUpdateTransport` — cert-pinned HTTPS (sha256 of DER), public CAs excluded.
- `update_gate.dart`: `ServiceHours` (wraps past midnight, default 08:00-04:00), `TillState` from the same numbers as the heartbeat, `UpdateGate.evaluate` — unsynced sales block always, rejected sales need support, sale-in-progress blocks, trading hours block routine updates, mandatory overrides the clock only when not the sole till; every hold worded for a manager.
- `update_service.dart`: check→verify→download→digest-check→stage→(install); https-only manifest URL enforced in constructor; stage statuses idle/upToDate/unreachable/waiting/downloading/staged/discarded/installed for diagnostics. **`installer` is nullable and `main.dart` passes none**, so on this build nothing is ever executed: staged-only. Classify: partial (pipeline done, platform installer not wired).
- `update_storage.dart`: file storage with re-read/re-verify at install time.

---

## 3. lib/domain

- `order.dart` (422) — IMPLEMENTED. `OrderType` dineIn/takeaway/delivery; `OrderState` draft/held/paid/synced; `KitchenStatus` pending/preparing/ready/served. `OrderModifier` (price captured at sale, optional backing productId so the server can move stock). `OrderLine`: uuid, qty (double, weighed goods), unitPrice, modifiers, note, per-line discount %, categoryId (for station routing), taxRate (tax-inclusive display only), printedToKitchen, firedStations[], fireAt (course timing, `dueAt`), seat (split-by-guest); `gross`/`total`. `Order`: uuid identity, deviceId, cashierId, createdAt (moment of sale), payments[], whole-order discount+reason, partnerId/customerName/phone/address, tableLabel, guestCount, note, deliveryCost, tip, kitchenStatus, refundOfUuid (`isRefund`), cashReceived (change display only, never booked), serverId (reference only); `total`=subtotal*discountFactor+delivery+tip; `amountPaid`/`balance` (running split balance); tax-inclusive `taxTotal`; `businessDay`. `toServerPayload()` folds line+order discounts into unit prices, zeroes discount fields on the wire, strips negative (local-customer) partner_id.
- `catalogue.dart` (130) — IMPLEMENTED. Category, Product (barcode, soldByWeight, taxRate), Modifier (fixed/percentage/free, `priceFor(parent)`), ModifierGroup (min/max/required, `isSatisfiedBy` enforced on-device), PaymentMethod (isCash), Customer.
- `identity.dart` — IMPLEMENTED. Secure-random RFC4122 v4 UUID; client identity everywhere, replay safety.
- `business_day.dart` — IMPLEMENTED. Trading-day with 04:00 local cutover; `key` = ISO date used in server payload as `business_date`.
- `shift.dart` — IMPLEMENTED. CashMovement (in/out, reason, expense category), Shift, ShiftSummary (expectedCash = float + cashSales + in − out; variance; card excluded from drawer).

---

## 4. lib/features (screen-by-screen)

### sell — IMPLEMENTED (the core, 2690 + 194 lines)
`sell_screen.dart`: two-pane (order panel 360px | catalogue grid). User can: search/filter by category/favourites; scan hardware barcodes (keyboard-burst heuristic, <150ms gaps + Enter); tap product (weighed → weight prompt; modifier groups → `ModifierSheet` with min/max/required enforcement, quantities per modifier); long-press product → 86/sold-out toggle + favourite pin (both gated `priceOverride`); line tap → actions sheet (kitchen note w/ quick picks, line discount w/ presets+cap, assign-to-guest, split-into-single-units, fire timing 0/5/10/15/20/30/45 min, void w/ mandatory reason quick-picks); +/- qty and trash only until kitchen holds the line, after which only Void (gate+reason+slips+audit); order-type chips (dine-in/takeaway/delivery) reshaping the context bar; dine-in: choose-table nudge, table chip via real floor-plan picker (occupancy colours; occupied-table seating blocked), guests, Split/move chip → bill options (split evenly N ways with running balance and last-share remainder; split by guest incl. Shared group; pay selected items with per-line unit dial, peel deferred to commit; move items to another table with discount carrying; merge another table in; whole-order course timing); delivery: details dialog (find-existing customer merging Odoo partners + local customers, name/phone/address/charge); order note; whole-order discount (gated `applyDiscount`, presets, cap enforcement with toast, reason quick picks); status chip (online/offline + N-to-sync); stale-catalogue banner (≥24h); Kitchen button with unsent count (long-press = resend whole ticket after confirm); Hold (parks, does NOT fire kitchen); Pay → `_PaymentSheet` (methods from synced catalogue deduped by name, cash-received quick amounts + change, tip, split tenders part-cash-part-card with remaining balance, books settled amount not tendered note); part-paid tabs settle balance-only on next Pay. End-shift button disabled mid-order.
`modifier_sheet.dart`: instant local modifier picker with validity messaging.

### auth — IMPLEMENTED
`login_screen.dart`: account chips (≤6) or type-to-search Autocomplete (roster >6; editing text drops selection), PIN keypad, distinct messages for wrong PIN / malformed / lockout with quoted wait, provisioning-PIN banner, build version label. All local.

### tables — IMPLEMENTED
`table_floor_screen.dart` (903): drawn floor plan with section tabs; view mode: tap table = start/recall dine-in (occupancy colours, running total + sitting-time ages ticking 30s); pick mode (`pickMode`) for seat/move flows with `exclude` and an "Other" free-text table; floor home shows Takeaway/Delivery start buttons; edit mode (hidden in pick mode): drag tables on a snap grid with hover cell, add table (name/seats/shape square-round-rectangle), add divider walls (orientation h/v, length 60-400 stepper, never occupiable), edit/delete with confirm, unique-name enforcement, add/rename/delete sections.

### orders — IMPLEMENTED
- `open_orders_screen.dart`: held-order cards, recall, cancel (manager-gated `cancelOrder`; fired lines demand a reason → kitchen cancel slips + deletion slip + audit).
- `order_history_screen.dart`: recent paid/synced (limit 1000), search by ref/table/customer, filters (order type, synced-only, last-N-days), reprint (gated `reprint`, marked REPRINT) and refund entry.
- `refund_screen.dart`: pick per-line refund quantities (doubles for weighed), reason, builds negative-quantity refund order linked by `refundOfUuid`, booked to acting cashier + this device; tenders reversed proportionally per original method (tests prove split-tender proportionality and tax carry).

### kitchen — IMPLEMENTED (same-device KDS)
`kitchen_display_screen.dart` (425): dark board, cards per active ticket (held/paid, not served), New→Preparing→Ready→Served advance buttons, 10s poll + 1s clock, SLA age colour thresholds, responsive 1-4 columns. Data source is the local order store on the same till (no cross-device sync).

### reports — IMPLEMENTED (10 screens, all pure views over on-till orders)
`reports_hub_screen.dart`: range filter Today/Yesterday/Last7/All, tiles to: sales summary (`sales_report_screen.dart`: gross, discounts, delivery income, tips, by order-type), top products (units vs revenue rankings), category report (uncategorised bucket kept), cashier report (per-cashier count/total/avg), payment analysis (per-method mix, empty payments = cash), sales by time (local-hour rush buckets), discounts report (order+line discount totals, by-reason breakdown), tax report (by rate, net/tax/gross, tax-inclusive), activity report (`activity_report_screen.dart`: refunds from orders + voids/cancellations parsed from audit log). Hub supports printing report rows via the shell's `_printShiftReport`.

### shift — IMPLEMENTED
`shift_screen.dart` (395): open shift with float (numeric pad), live X summary (sales count/total, cash sales, in/out, expected drawer), cash in / cash out with reason + expense categories (Transport/Food/Supplies/Maintenance/Other), print X read, close (Z): counted-cash prompt → variance confirm dialog → `authorizeClose` gate → close → Z dialog (printable) → `onCloseSync` batch push message.

### admin — IMPLEMENTED
- `roster_screen.dart` (335): add cashier (name/role/PIN, local Argon2id), edit role, reset PIN, deactivate/reactivate; `canAssignManager=false` for delegated cashiers (no self-promotion; cannot touch manager accounts).
- `roles_permissions_screen.dart`: manager fixed-full read-only row; per-`Permission` switches for cashier role; explainer that unchecked still works via manager PIN.
- `attendance_screen.dart`: clock in/out per staff, live worked durations, multiple concurrent.

### customers — IMPLEMENTED
`customer_management_screen.dart` (293): list/search/add/edit/delete local customers (name required, phone, address), delete confirm; feeds the sell-screen customer picker.

### onboarding — PARTIAL
`wizard_overlay.dart`: presentational stepper coach overlay (completed/skipped/dismissedForever outcomes). Only the first-sale wizard is mounted (see §2 onboarding).

### settings — IMPLEMENTED (8 screens)
- `settings_hub_screen.dart`: grouped entry list (shell builds entries; see pos_app).
- `shop_settings_screen.dart`: shop name, tax id, footer, show-tax toggle.
- `receipt_designer_screen.dart` (414): header line, footer, toggles (cashier, order type, tax id, datetime, number, table, payment, item prices), divider style (line/equals/dots/stars), paper width 80mm/58mm, receipt copies, open-drawer-on-sale, live preview matching builder maths, test print.
- `printers_screen.dart` (622): add/edit/remove printers (name+host+port, suggestion chips), test print per printer (no fallback), category→station multi-select routing chips, per-product override checklist with category filter + search, station renames repoint routing.
- `quick_comments_screen.dart`: kitchen-note quick-pick CRUD.
- `discount_settings_screen.dart`: preset percentages CRUD, max-discount cap, reason CRUD.
- `appearance_settings_screen.dart`: 10-swatch colour per category, clear.
- `server_settings_screen.dart`: Odoo URL/db/login/password with on-screen warning that a real fleet must not hold the shared credential; save rewires the live sender without restart.

### support — IMPLEMENTED
- `diagnostics_screen.dart` (471): honest till status (device id, app version, pending sales vs heartbeat-excluded counts, dead/rejected sales with retry (revive), oldest-waiting age, catalogue age, last error verbatim, needs-attention banner, "No server configured" vs offline distinction, unhandled kinds named), copy-for-support, manual Sync now (`sync.tick`), printer list with rescan/find-receipt-printer/manual add-edit-forget (gated `managePrinters`), spooled receipt reprint, update status + manual check, wizard re-offer.
- `audit_log_screen.dart`: filterable audit viewer (event kind, colour-coded families), CSV export via clipboard, empty state.

---

## 5. docs — intended design & invariants

- `docs/ARCHITECTURE.md`: why (Odoo POS dies on cold-start offline because only orders persist to IndexedDB, never the catalogue); prime rule "till owns its data; server is a destination, not a dependency"; client-UUID identity; outbox = one-way queue, no merge; migrations additive-first; two-layer auth (device enrolment + local PIN); ESC/POS text not raster; update gating; Odoo remains system of record. **Stale spot:** Storage section still says SQLCipher "not implemented" — it now is (main.dart:54-60, pubspec `sqlcipher_flutter_libs`, encryption tests).
- `docs/ODOO_SYNC.md`: offline sale books the FULL chain in Odoo (sale.order → confirm → delivery validated → posted invoice → payment registered) via `pos_offline_sync` module method `sale.order.create_from_offline_pos`; valuation backdated via jouma's `stock_accounting_date_adjustment`; **sync at shift close as one batch**, never per order (single shared integration login `offlinepos_sync`); background loop is read-only (probe + catalogue); per-order status dicts created/duplicate/rejected with per-order savepoints; transient-vs-permanent taxonomy; queue kinds order.push/audit.push/device.status; integration-user group requirements table; catch-up maths for week-long outages.
- `docs/SECURITY.md`: binary-is-public assumptions, no secrets in app, Argon2id + attempt limits mandatory, SQLCipher + keystore, server-side authorization, licensing must never block a sale, signed auto-update or it is RCE. Go-live checklist: DONE = no secrets, PIN policy, encrypted DB, signed+pinned updates; OPEN = backend deny-by-default rules, dependency audit, agents loopback-bound, secret rotation.
- `docs/WINDOWS_TEST.md`: single-operator Windows test guide (flutter run -d windows; provisioning PIN; point at Odoo in-app or via dart-defines; offline story walkthrough; known limits: LAN printers only/no USB, rescue session opened in Odoo, encrypted-at-rest with credential-store key).

---

## 6. test/ — 510 tests; what is proven to work

- Domain: business-day cutover incl. month boundary; order maths, payload discount folding, negative-id partner stripping, cash overpayment booking, seats/payCheck/course-timing/move-merge discount invariants (`test/domain/*`, `test/app/pos_session_test.dart`, `pos_session_split_test.dart`).
- Auth: full unlock matrix, per-cashier durable lockout, unknown==wrong PIN, audit offline, roster replace safety, Argon2id properties, malformed-hash rejection, bootstrap PIN uniqueness/regeneration (`test/core/auth_service_test.dart`, `pin_*`, `bootstrap_cashier_test.dart`, `test/db/auth_attempts_test.dart`).
- DB: catalogue persistence/refresh atomicity/staleness, **SQLCipher proof** (key reuse, ciphertext not cleartext, wrong key rejected, plaintext control) in `test/db/encryption_test.dart` (loaders `sqlcipher_loader.dart`/`sqlite_loader.dart`), shift store X/Z + card-vs-cash, table store shapes/dividers, attendance.
- Sync: outbox ordering/idempotency/dead-letter/park-and-continue/no-sender-keep/backlog drain; sender error taxonomy incl. captive portal + session expiry + module statuses; wiring (audit never posted as sales, disable, queue-before-endpoint); sync service (refresh never pushes orders, reconcile of lost enqueues, empty pull never wipes catalogue, online badge honesty); heartbeat semantics (replace-not-accumulate, excluded from pending/age) (`test/core/outbox_test.dart`, `odoo_sender_test.dart`, `sync_service_test.dart`, `heartbeat_test.dart`, `puller_test.dart`, `test/sync/*`).
- Printing: ESC/POS byte-exactness, code-page/no-character-loses-a-receipt, receipt builder toggles/change/deletion slips/refund banner, kitchen routing fan-out, TCP fail-fast/retry vs real sockets, discovery bounds, registry resolution/backoff/identity/persistence, durable spool across restart (`test/printing/*`, `spool_persistence_test.dart`).
- Updates: version comparison, signature-or-nothing manifest handling, gate matrix (unsynced sales absolute, mandatory-vs-sole-till, service hours wrap) (`test/updates/*`, release key fixture `release_key.dart`).
- UI widget tests for nearly every screen: login (incl. search roster), sell (incl. dine-in split/move/merge flows in `test/ui/sell_dine_in_test.dart`), floor screen, open orders, history, refund (split-tender proportional reversal), KDS (SLA colours, ticking clocks, responsive columns), shift, printers (routing chips, per-product overrides), receipt designer (live preview), reports hub + each report, roster/roles/attendance/customers/quick comments/appearance/audit log/diagnostics (14 diagnostics assertions incl. gated printer add), wizard overlay/store.
- `test/staging/*` (6 files): END-TO-END against a real Odoo staging build over HTTPS (real `OdooWiring`/`OdooSender`), skipped unless `--dart-define=STAGING_URL/DB/LOGIN/PASSWORD`: order push books, payment method books, 25% discount books reduced total, catalogue pull, full path configure→pull→store→read.

## 7. Platforms & launch

- Platform folders: `windows/` (primary target; runner + CMake), `linux/` (CMake, binary `offline_pos`, id `eg.codesolution.offline_pos`), `android/` (Gradle KTS, applicationId `eg.codesolution.offline_pos`, MainActivity kotlin). No ios/, no macos/, no web/.
- Launch: `flutter run -d windows` (see docs/WINDOWS_TEST.md); dart-defines: `APP_VERSION`, `ODOO_URL/ODOO_DB/ODOO_LOGIN/ODOO_PASSWORD` (optional default endpoint), `OFFLINE_TILL_ID` (default `till-1`), `SHOP_NAME/SHOP_TAX_ID/RECEIPT_FOOTER`, `UPDATE_MANIFEST_URL/UPDATE_PUBLIC_KEY/UPDATE_CERT_PINS`, `SOLE_TILL`.
- CI: `.github/workflows/windows-build.yml` (push to main: pub get, analyze, test, build windows release, zip artifact; GitHub-owned actions only), `appveyor.yml` (same, with modern sqlite3.dll fetch for tests via `SQLITE3_DLL` env), `codemagic.yaml` (Windows workflow, Flutter 3.41.6). All three build Windows only.
- Dependencies (pubspec.yaml): crypto, cryptography (Argon2id/Ed25519), sqlite3, sqlcipher_flutter_libs, flutter_secure_storage, http, path_provider, flutter_localizations. SDK ^3.11.4.

## 8. Summary classification table

| Area | Status | Notes |
|---|---|---|
| Selling core (catalogue, lines, modifiers, weighed, barcode, discounts, payments incl. split tender/tip/change) | implemented | sell_screen + pos_session, heavily tested |
| Dine-in (floor plan, sections, dividers, hold/recall, seats, split by guest/item/even, move/merge, course firing) | implemented | commits through HEAD are all in this area |
| Payments to Odoo (batch at shift close, idempotent uuid, dead-letter, reconcile) | implemented (local-test topology) | needs `pos_offline_sync` module server-side; fleet backend + per-device tokens NOT built |
| Catalogue pull (products/categories/modifiers/taxes/payment methods/customers) | implemented | modifier models optional add-on, degrades |
| Printing (ESC/POS TCP 9100, receipts, KOT multi-station routing, void/cancel slips, durable spool, discovery/registry) | implemented | USB/BT not wired |
| Kitchen display | implemented | same-device only |
| Shifts/cash-up (X/Z, movements, expense categories, close-sync) | implemented | |
| Reports (10) + audit viewer | implemented | on-till data only |
| Auth (PIN, Argon2id, lockout, roles/permissions, manager elevation, provisioning) | implemented | |
| Device enrolment token / fleet auth | stub | model+test only (`device_token.dart`), nothing wired |
| audit.push / device.status server delivery | stub | queued+locally acked, no server sink (odoo_wiring.dart:46-52) |
| Encrypted storage (SQLCipher + keychain) | implemented | ARCHITECTURE.md claim of "not implemented" is stale |
| i18n en/ar + RTL | implemented | 426 ar strings |
| Onboarding wizards | partial | 1 of 5 wizard ids mounted |
| Updates (signed manifest, pinning, gate, staging) | partial | no installer wired in main.dart → staged, never executed |
| Remote wipe (SECURITY.md) | not built | |
| Android/Linux runners | scaffolded, untested in CI | CI builds Windows only |


---

# DETAILED FINDINGS: Dishflow (DishFlow) UI Screens + Navigation Inventory

# Dishflow (DishFlow) UI Screens + Navigation Inventory

Repo: `/home/username/workspace/Dishflow-pos` (Flutter + Firebase restaurant POS, branch Test). All paths below are relative to the repo root unless absolute. App is Arabic-first (RTL) with a runtime AR/EN toggle; landscape-only.

---

## 1. Navigation architecture

- **No named-route table.** All navigation is imperative `Navigator.push / pushReplacement / pushAndRemoveUntil` with inline `MaterialPageRoute`s. `RouteSettings(name: ...)` is set ad hoc on important routes (`/mode_selection`, `/login`, `/home`, `/pos_mode`, `/rm_mode`, `/transaction_mode`, `/firebase_check`, `/force_logout_progress`) purely for audit logging.
- `lib/core/navigation/app_navigator.dart` (5 lines): a single global `appNavigatorKey` (`GlobalKey<NavigatorState>`) used for dialogs/navigation from outside the widget tree (force logout, dev badge, SLA monitor).
- `lib/core/navigation/audit_navigator_observer.dart`: `AuditNavigatorObserver` registered on `MaterialApp.navigatorObservers` (`lib/main.dart:290`). Logs every screen open/close (`screen_open`/`screen_close`, category `navigation`) to `AuditLogService`, resolving names from `RouteSettings.name` or route runtimeType; ignores dialog/popup/bottom-sheet routes (list at lines 14-22).
- **Entry point** `lib/main.dart`:
  - `main()` (line 81): Sentry init wrapper, then `_bootstrapApp()` (line 122): Firebase init (per-branch project via `lib/firebase_configs/*` and dev switcher `lib/core/dev/dev_firebase_selector.dart`), Firestore offline persistence, named app `menu`, anonymous identity sign-in, Odoo API init, printer init, cashier shift + app-mode load, then forces landscape (`SystemChrome.setPreferredOrientations`, lines 245-248) and runs `POSApp`.
  - Providers (lines 252-263): `ThemeProvider`, `LocaleProvider`, `CustomerDisplayService`, `DailyStockController`.
  - `MaterialApp` (lines 286-303): `theme: AppTheme.lightTheme`, `darkTheme: AppTheme.darkTheme`, `supportedLocales: [ar, en]`, Material/Widgets/Cupertino localization delegates.
  - `builder` (lines 304-369): wraps everything in `Directionality(rtl if Arabic)`, adds a top overlay strip with a green/white env dot + active session id label, dev-only Firebase project switcher badge (`_DevFirebaseBadge`, line 413), and a bottom-pinned global `KitchenSendBanner` that survives route changes.
  - `_ForceLogoutGate` (lines 518-613): listens to `SessionStatusWatcher.forceLogoutTick`; on remote session close it pushes `ForceLogoutProgressScreen` (fullscreen, `pushAndRemoveUntil`), tears down shift/Odoo session/mode, then lands on `ModeSelectionScreen`.
  - **Web URL-mode dispatch** `_getInitialScreen()` (lines 376-406):
    - `?mode=customer-display` -> `CustomerDisplayStandaloneScreen`
    - `?mode=menu` -> `MenuSplashScreen` (customer QR menu)
    - `?mode=kiosk` -> `KioskScreen`
    - `?mode=demo` -> `HomeScreen(userName:'demo', initialSelectedIndex:1)` (straight to POS in demo)
    - `?mode=local-orders` -> `OrderSyncDiagnosticsScreen` (offline-safe local orders index)
    - `?mode=rm-web` (or host `reports.code-solution.org`) -> `RmWebLoginScreen`
    - default -> `SplashScreen`.

---

## 2. Boot + auth gating flow

### SplashScreen, `lib/features/auth/presentation/splash_screen.dart`
Animated brand mark + spinner. After ~1.2s `_checkSession()` (lines 63-219) decides:
- RM web host -> `RmWebLoginScreen`.
- No app mode chosen yet -> `ModeSelectionScreen` (mode is device-scoped; RM mode is cleared if not on RM web host).
- `OdooApiService().checkSession()`:
  - `loggedIn`: loads Firebase permissions; role cashier/delivery forces POS tab (`posIndex=1`); syncs local session with Firebase; non-admin users are bounced off admin-only modes back to `ModeSelectionScreen`; then routes by mode: `AppMode.pos`/`delivery` -> `PosModeShell`, `AppMode.rm` -> `RmModeShell`, `AppMode.transaction` -> `TransactionModeShell`, else (admin) -> `HomeScreen`.
  - `serverConfigured` (not logged in) -> `LoginScreen`.
  - `fresh` (first run) -> `FirebaseCheckScreen`.

### ModeSelectionScreen, `lib/features/auth/presentation/mode_selection_screen.dart`
First-run device mode picker with 5 large cards (lines 117-175): POS (نقاط البيع), Admin (مدير), Report Management/RM (إدارة التقارير, reports only), Delivery (دليفري, delivery-restricted POS), Transaction (المعاملات, payments/movements log only). Top-right AR/EN language toggle (`_LanguageToggle`). Selecting a card persists `AppModeService().setMode` then `pushReplacement -> LoginScreen` (lines 37-46).

### LoginScreen, `lib/features/auth/presentation/login_screen.dart` (2671 lines)
Smart login card with 4 modes decided by `_detectQuickLoginMode()` (lines 816-876):
- `fingerprint`: local fingerprint agent (127.0.0.1:9201) up + eligible templates; auto-triggers `FingerprintDialog` after 600ms; two-step verify for non-admins (user fingerprint then admin fingerprint approval, lines 541-646).
- `pin`: renders `PinPad` widget (below), titled "دخول بـ PIN". `_handlePinLogin` (line ~1040) matches PIN hash against `pos_users` via `QuickLoginService.findUserByPin`, decrypts the stored Odoo password, calls `OdooApiService.login(allowOfflineLogin:true)` (has an offline SharedPreferences cache fallback), then `_navigateToHome`.
- `classic_bootstrap`: no quick-login user exists yet, shows classic username/password form.
- Classic fallback link always available for users with no fingerprint/PIN (lines 1274+).
- Manager-approval dialog for privileged fallback (line 334), admin-picker bottom sheets (lines 1839, 2088, 2188).
- `_navigateToHome` (lines 780-810): sets activity-logger identity, enforces per-user `allowedModes` (blocks + logs out if the current device mode is not permitted), then `pushReplacement -> SyncScreen(userName)`.
- Back button `_goBackToModeSelection` (lines 768-778): clears mode, `pushReplacement -> ModeSelectionScreen`.
- Server icon pushes `ServerSetupScreen` (lines 1412-1413).
- Custom animated `_BackgroundPainter` (line 2635).

### PinPad widget, `lib/features/auth/presentation/widgets/pin_pad.dart`
Reusable numeric PIN keypad: title/subtitle, dot progress indicator (min 4 / max 6), inline error chip, 3x4 keypad + clear/backspace action keys, full-width "دخول" (submit) FilledButton with loading state. Calls `onSubmit(pin)`. Used by LoginScreen, PosModeShell logout, discount auth, reentry dialogs.

### FirebaseCheckScreen, `lib/features/auth/presentation/firebase_check_screen.dart`
First-run gate. States enum: loading/success/noConnection/subscriptionExpired/userBlocked/error. On success: if Odoo already authenticated -> `SyncScreen`, else -> `LoginScreen` (lines 100-127). Error actions: open `FirebaseProjectSettingsScreen` (line 334-335) or fall back to manual `ServerValidationScreen` (line 352-353).

### ServerSetupScreen, `lib/features/auth/presentation/server_setup_screen.dart`
Manual Odoo server URL + database form; on success `pushReplacement -> LoginScreen` (lines 108-109).

### ServerValidationScreen, `lib/features/auth/presentation/server_validation_screen.dart`
Validates server/db reachability; success -> `LoginScreen` (lines 97-98).

### SyncScreen, `lib/features/auth/presentation/sync_screen.dart`
Post-login data sync (products, categories, customers from Odoo, progress list UI). Cancel path -> `pushAndRemoveUntil ModeSelectionScreen` (lines 349-352). On completion `_navigate` (lines 408-460) routes by `AppModeService().current`: pos/delivery -> `PosModeShell`, rm -> `RmModeShell`, transaction -> `TransactionModeShell`, admin/default -> `HomeScreen(userName)`. This is the first authenticated-area screen asserted in `integration_test/login_pin_journey_test.dart`.

### Auth dialogs
- `cashier_login_dialog.dart`: opens a new cashier shift before selling; pick name from `pos_users` + Odoo password verify; creates `CashierShift` bound to the open session.
- `manager_auth_dialog.dart`: generic manager credential/PIN verification returning `ManagerAuthResult`; used to gate sensitive actions.
- `transfer_orders_dialog.dart`: manager-gated transfer of open tables (sent-to-kitchen, unfinished) from one cashier to another within a session.
- `widgets/quick_login_setup_dialog.dart`: admin sets a user's quick login (verifies Odoo password, sets 4-6 digit PIN); opened from Users Management.
- `pos/presentation/dialogs/cashier_selection_dialog.dart`: cashier picker + PIN when opening a new table (returns `CashierSelectionResult`).
- `pos/presentation/dialogs/cashier_reentry_pin_dialog.dart`: PIN-only verification when re-entering an occupied table or resuming a suspended order (no cashier dropdown).
- `pos/presentation/dialogs/table_access_dialog.dart`: opening a table reserved by another cashier; supports admin override while keeping order attribution (`TableAccessResult.isAdminOverride`).

### RM Web portal (reports.code-solution.org)
- `rm_web_login_screen.dart`: web-only manager login (email/password against `rm_managers`); multi-branch manager -> `push RmWebBranchSelectionScreen(manager)` (lines 274-275); single branch -> `pushReplacement RmModeShell(onLogout: back to RmWebLoginScreen)` (lines 177-180). Branch selection switches the Firebase project via `lib/core/rm_web/rm_web_firebase_switcher.dart` and reloads.
- `rm_web_branch_selection_screen.dart`: card list of branches for the manager (light indigo theme), selects branch -> RM shell.

---

## 3. Mode shells (top-level chrome per device mode)

### HomeScreen (Admin mode shell), `lib/features/pos/presentation/home_screen.dart` (5920 lines)
The all-features shell. `_selectedIndex` drives an internal switch (no Navigator pushes between sections), with the POS tab kept alive in an `Offstage` Stack slot so cart state survives tab switches (lines 4261-4373).

- **Section index map** (audit names, lines 3546-3565): 0 Dashboard (لوحة التحكم), 1 POS/Tables (نقطة البيع/الطاولات), 2 Products, 3 Orders, 4 Customers, 5 Reports, 6 Expenses, 7 Settings, 8 Printers Management, 12 Customer Display, 14 Warehouse Order, 15 Delivery Orders, 16 Menu Orders, 17 Menu Engineering, 18 Loyalty, 19 Kitchen Display, 20 Coupons, 21 Advanced Analytics, 22 Stock Count (الجرد).
- **Foreground switch** (lines 4296-4362): index 1 renders `TableReservationScreen` when `canUseTables && tableSelectionEnabled`, else a bare `POSScreen`; edit mode overlays a fresh `POSScreen(editingOrder: ...)` keyed per order (lines 4300-4317); 2 `ProductsScreen`; 3 `OrdersWithTabsScreen`; 4 `CustomersScreen`; 5 `_buildReportsContent`; 6 `ExpensesScreen`; 7 `SettingsMenuScreen`; 8 `PrintersManagementScreen`; 12 `CustomerDisplayScreen`; 14 `WarehouseOrderScreen`; 15 `DeliveryOrdersScreen` (shipping); 16 `MenuOrdersScreen` (with load-to-cart callback that converts a menu/kiosk order into POS cart items and jumps to index 1, lines 4340-4348); 17 `MenuEngineeringScreen`; 18 `LoyaltySettingsScreen`; 19 `KitchenDisplayScreen`; 20 `CouponsScreen`; 21 `AdvancedAnalyticsScreen`; 22 `DailyStockScreen`.
- **Reports sub-navigation** `_reportsSubIndex` (lines 4375-4418): 0 `ReportsMenuScreen` (tile menu), 1 `ReportsDashboardScreen`, 2 `DetailOrdersReportScreen`, 3 `ItemsSalesReportScreen`, 4 `AnalyticsMenuScreen` (which swaps in one of 8 analytics screens via `_analyticsReportScreen`), 5 `DiscountsReportScreen`, 6 `ExpenseReportScreen`, 7 `CostVsSalesReportScreen`, 8 `DeliveryReportScreen`, 9 `CurrentSessionPaymentsReportScreen`, 10 `SessionCloseScreen` (with `onNavigateToTables` jumping back to POS), 11 `DeliveryReportDriversScreen`.
- **Sidebar** `_buildSidebar` (lines 2852-3330): logo + wordmark, user card with role badge, permission-filtered nav items (each guarded by `FirebasePermissionService` flags such as `canViewPOS`, `canViewReports`, `allowedScreens`), AI Assistant item that opens `AiChatPopup` overlay instead of navigating (line 3083), Settings below a divider, Light/Dark theme segmented toggle, AR/EN language toggle, "Powered by Code Solution", logout button (non-admin roles must pass fingerprint checkout `_handleCheckoutFingerprint`, lines 3246-3260; logout goes through `_LogoutRedirect` (lines 115-165) which clears state and lands on `ModeSelectionScreen`). Sidebar auto-collapses to 80px on the POS tab unless pinned (line 2853), with a pin toggle shown only on POS (line 3305).
- **Layout modes** (lines 2004-2011): `menu_position` setting (`LocalStorageService.menuPositionNotifier`, 'left' default or 'bottom') switches between sidebar layout and bottom-nav layout. Bottom nav (lines 1636-1727): 4 primary items (Home, POS, Orders, Reports) + "More" overlay grid (`_getMoreItems`, lines 1734+) containing everything else, plus POS-contextual actions (Session Orders, Session Payments).
- **POS bottom action bar** (sidebar layout, POS tab only, `_buildPOSBottomBar`, labels at lines 3375-3431): إتمام الطلب (checkout), حذف السلة (clear cart), تعليق الطلب (suspend), دمج الطلب (merge), إرسال للمطبخ (send to kitchen), Misc, طلبات الجلسة (session orders dialog, line 2097 `SessionOrdersDialog`), مدفوعات الجلسة (jumps to reports sub-index 9).
- **Dashboard** (index 0, `_buildDashboard`, lines 4420+): greeting header, quick search icon (Ctrl+K opens `QuickSearchOverlay`: products/customers/orders search that can deep-link to sections), session-date chip, Today/Month filter chips, stats cards, `SmartAlertsWidget`, recent orders list; on return to dashboard it may prompt to merge unsynced orders from a previous session (lines 3618-3627).
- **Keyboard shortcuts** (lines 2025-2031): F2 open POS, F5 refresh dashboard, Esc close, Ctrl/Cmd+K quick search.
- **Session guard**: switching to POS with no active session opens the "open new session" confirm dialog (shift auto-derived from time of day, lines 3573-3576 and 3634+); leaving POS with items auto-suspends the cart and blocks the switch if suspend fails (lines 3579-3591).

### PosModeShell (POS / Delivery locked mode), `lib/features/auth/presentation/pos_mode_shell.dart` (2626 lines)
Locked-down cashier device shell (doc lines 53-64: no sidebar, no bottom nav, no settings). Body = `TableReservationScreen(useDemoMode:false, forcedAllowedOrderTypes: ...)` + invisible ecommerce-order sound alarm host (lines 2112-2121). Order types forced per mode: delivery mode = company/store/car delivery, POS mode = Dine-in/Takeaway, overridable per user permissions (lines 1865-1878).
Top AppBar (56px) chips, permission-gated (`isPosFeatureAllowed`, lines 1956-2097): Logout (admin PIN/fingerprint dialog, lines 81+), Flash Report (manager auth -> per-cashier or aggregated session flash preview dialog with print, lines 1723-1850; delivery mode auto-opens Delivery Flash via transparent-route `ReportsMenuScreen(autoOpenDeliveryFlashOnly:true)`, lines 1729-1743), Transfer Table (manager/admin), Session Orders (`SessionOrdersDialog`, line 424), Kiosk Orders chip + "Kiosk Screen" opener (web window), Stock (pushes a scaffolded `POSScreen(stockMode:true)`, lines 2020-2049), Suspended orders, delivery-mode-only Store Delivery / Company Delivery lists (both `DeliveryOrdersScreen` from shipping with filters, lines 2060-2086) and Sync (`OrderSyncDiagnosticsScreen`, lines 2087-2097). A "Back" chip appears while inside POS (via `PosModeNavigationBus.isInPosNotifier`) returning to the tables board. Delivery mode wraps the shell in `_DeliverySlaHost` starting `DeliverySlaMonitor` (late-delivery alert dialogs via global navigator key).
`lib/features/pos/presentation/pos_mode_navigation_bus.dart`: tiny notifier bus connecting shell AppBar to the embedded `TableReservationScreen` (back-to-tables action, resume-order action, load-menu-order action, in-POS state).

### RmModeShell (reports-only), `lib/features/auth/presentation/rm_mode_shell.dart`
Light analytics chrome (forced light `ThemeProvider`, `RmLightDashboardTheme`). Left `RmSidebar` (drawer under 900px width) + right pane hosted in its own nested `Navigator` keyed by leaf id (lines 76-153). Default content: `ReportsDashboardScreen(embeddedInRmShell:true)`. Logout -> `ModeSelectionScreen` or custom web handler.
`lib/features/auth/presentation/widgets/rm_sidebar.dart` leaves (lines 122-300): Items Sales, Detail Orders, Reports Menu (flash reports), Current Session Payments, Discounts, Detailed Discounts, Revenue Center, Tax Report, Cost vs Sales, Expenses, Delivery Report, Audit Trail, ETA Invoice Wizard, ETA Invoice History; analytics group: Top Products, Category Performance, Sales by Time, Sales by Day, Cashier Performance, Period Comparison, Modifier Analysis, Payment Analysis; plus Cashier Performance and Cancelled/Modified Orders entries; language toggle at bottom. Report screens are wrapped by `rm_light_page_wrapper.dart` and re-themed via `rm_report_theme.dart`; `rm_shell_scope.dart` lets nested screens detect RM chrome; `rm_dashboard_right_panel.dart` provides quick actions.

### TransactionModeShell, `lib/features/auth/presentation/transaction_mode_shell.dart`
AppBar (title المعاملات + user + Logout) with body = `ActivityLogsScreen` pre-filtered to today (lines 116-129). Logout -> `ModeSelectionScreen`.

---

## 4. POS sell screen, `lib/features/pos/presentation/pos_screen.dart` (25,812 lines)

`POSScreen` (line 782) is a body-only widget (no Scaffold) hosted by HomeScreen/TableReservationScreen/PosModeShell. Key constructor params: `useDemoMode` (demo product list `_demoProducts` ~line 1177, skips session gating and Firebase saves), `initialTableNumber`, `initialGuestCount`, `editingOrder`/`onEditingDone`, `initialMenuOrder`, `stockMode`, `forcedAllowedOrderTypes`, `allowedPaymentMethodIds`, `actionNotifier`/`cartCountNotifier` (remote commands from HomeScreen bottom bar), `onSessionOrders`, `onPrintSessionPayments`.

- **Root layout** `build` (lines 13677-13774): `PopScope` blocks back-nav during checkout; F12 shortcut = quick checkout; `LayoutBuilder` Row = products section (Expanded, RepaintBoundary) + fixed-width cart column (420px on >1400px screens, else 32% of width, clamped to min 260; responsive clamping for narrow windows, lines 13723-13736). Cart column intentionally rendered with the inverted theme for contrast (line 13761). Stock mode hides the cart entirely (line 13750). A cashier-lock overlay covers the screen when cashier re-login is required (line 13766, `_buildCashierLockOverlay` 13776+).
- **Products region** (lines 13843-14030): two layouts via `products_layout` setting: `top` (header + horizontal category chips + product count above grid) or `side` (140px vertical category rail with its own search box + grid). Header includes search field; grid-size toggle (S/M/L via `ProductGridSize`, lines 14568-14650); `_buildProductsGrid` (14653) and `_buildProductCard` (14772) with Odoo image loading (15028); category chips honor custom colors/shapes from Category Colors settings; demo categories rows for demo mode.
- **Cart region** (lines 15054-18063): `_buildCartSection` swaps `modern`/`classic` styles from `cart_style` setting (line 15056, naming inverted in code). Includes: table/guest header with guest-count edit via `showGuestCountDialog` (lines 15183, 15424), order-type dropdown `_buildOrderTypeSelector` (lines 7965-8028, values from `_allowedOrderTypes`: Dine-in, Takeaway, Delivery from company, Store delivery, Car delivery; switching to a delivery type warms up the delivery dialog data), shipping company selector (8031), customer selector (8122), guest-split selector row (15326, 20124), cart line rows (table style `_buildCartTableRow` 16147 or card style `_buildCartItem` 16819) with modifier sub-rows (16545), qty +/- buttons (18056; decrement to 0 asks confirm, `_updateQuantity` ~5300 and `_removeCartLineByCount` ~5359), per-line note/additions pencil, per-line delete with reason (deletion notes "DEL: ..." merged into the line note, lines 5809, 6068), empty-cart placeholder (16636).
- **Cart summary** `_buildCartSummary` (18079-18564): subtotal, tax 14% (`AppLocale.taxRate`, label at 18165), delivery charge button for chargeable delivery types (18327-18368), invoice discount row (خصم الشيك, 18370-18397), split-among-people banner with cancel (18277-18300), quick action icon row (18401-18511): Suspend (تعليق), Kitchen Hold toggle, Clear (مسح, opens delete-options dialog with manager approval + deletion receipt printing), Discount (خصم, `_openDiscountDialogWithAuth` 3234: admin-PIN "تفويض الخصم" authorization dialog 3248+, then discount dialog with type percentage/fixed + reason from configurable discount types; persisted immediately so it survives leaving the table), Move Items (نقل أصناف -> `_MoveItemsSelectionDialog` + zone/table picker), Guest Split setup/cancel, Print Receipt (only after kitchen send). Bottom row (18513-18560): kitchen schedule button, "إرسال للمطبخ" send-to-kitchen button (routes items per printer via `printer_routing_helper.dart`; preview dialog `KitchenPreviewDialog` when no kitchen printer, lines 11328-11340; partial-failure dialog `KitchenPartialErrorDialog` at 4398-4401; resend button 13297), and the main checkout button "إتمام الطلب / Place Order" (18528-18556) -> `_showEnhancedCheckoutDialog`.
- **Adding items**: tapping a product card adds it to cart; products with attributes/modifiers open `ProductModifierScreen` inside a dialog (lines 4777, 5217); long-press/pencil on a multi-qty line opens `UnitModifiersSelectorScreen` (per-unit modifiers, `unit_modifiers_selector_screen.dart`); note + general-additions bottom sheet `_showProductNoteBottomSheet` (17375+, loads `GeneralAdditionModel` extras per product template, quick comments from Firebase quick-comments service, supports applying a note to a subset of the quantity which splits the line, 17646+, 18006).
- **Guest split mode**: banner over products (20263), per-guest cart attribution, active-guest selector (20124), per-guest kitchen tickets (11688).
- **Suspend/resume**: `_suspendCart` saves to suspended orders (badge widgets `_SuspendedOrdersBadge` 23468, `_SuspendedOrdersTopButton` 23624); resume flows come from tables board / session dialog.
- **Dialogs defined in-file**: `_CheckoutInfoDialog` (219, customer + driver picker when a shipping company is selected), `_OrderLinesPickerSheet` (605), `_SelectOrderLinesDialog` (648), `_PendingOrdersListSheet` (737), `_ZoneTablePickerDialog` (23714, table grid per section with seat visuals + legend), `_SplitMoveOptionsDialog` (24577), `_MoveItemsSelectionDialog` (24756, item+qty multi-select, reused for partial pay), `_PaymentModeDialog` (25123), `_SplitByPeoplePaymentDialog` (25289, per-person share cards each with an "ادفع/Pay" button at 25534), `_MergeOptionsDialog` (25637).
- `lib/features/pos/presentation/stock_management_screen.dart` is a 1-line tombstone: stock screen is now `POSScreen(stockMode:true)`.

---

## 5. Table selection screens

### TableReservationScreen, `lib/features/pos/presentation/table_reservation_screen.dart` (4888 lines)
The tables board shown as the POS tab when table selection is enabled, and as the whole body of PosModeShell. Left order-type sidebar (Dine-in/Takeaway/delivery types), section tabs (configurable order), live table grid streamed from `FirebaseTableService` with status colors and seat visuals, plus pending/suspended order cards per order type. Flow to POS:
1. Tap free table -> `CashierSelectionDialog.show` (line 689) -> `showGuestCountDialog` (line 704, skippable per section config `requireGuestCount`, line 519) -> embeds `POSScreen` (line 1922) with table + guest count.
2. Tap occupied table -> resume/cancel dialog (lines 837-846) -> `CashierReentryPinDialog.show` (927) or table-access/admin-override flow.
3. Delivery types -> optional shipping-company pre-pick dialog (lines 2522-2584) then POS.
Also: auto-opens cashier shift for managers (225), admin "الحضور" tile -> `CashierAttendanceScreen.show` (3288, 3532), gear tile -> `TablesManagementScreen` push (3279-3280, 3519-3520, 3723), kiosk/menu order injection via `PosModeNavigationBus` (1810+), edit-order entry from `SessionOrdersDialog` (432+), delivery SLA alerts, `_resumeVersion` ValueKey trick to force fresh POSScreen instances per table (389-396).

### TablesManagementScreen, `lib/features/pos/presentation/tables_management_screen.dart` (3282 lines)
Admin CRUD for sections and tables (add/edit/delete tables, seats, sections layout tabs/grid); reached from tables board gear and Settings menu.

### Guest count dialog, `lib/features/pos/presentation/guest_count_dialog.dart`
`showGuestCountDialog(context, tableNumber, recommendedSeats)` returns the entered guest count or null; numeric pad UI.

---

## 6. Payment flow

Entry: cart "إتمام الطلب" button or HomeScreen POS bottom-bar checkout -> `_showEnhancedCheckoutDialog` (pos_screen.dart:19585).

1. **_PaymentModeDialog** (25123-25233): options Full ("دفع كامل" -> `_showCheckoutDialog`), Pay Selected Items ("دفع جزئي" -> `_showPartialPaymentFlow` 19675: `_MoveItemsSelectionDialog` item+qty picker, partial total = selected x (1+14% tax), then PaymentMethodDialog, saves its own partial order + auto-prints), Split by People ("تقسيم على أشخاص" -> `_showSplitByPeoplePaymentFlow` 19628 / `_SplitByPeoplePaymentDialog`: N equal shares, each share paid via its own PaymentMethodDialog at 25373), and Pay Guest N (guest-split mode only, 25170-25183). Anti-double-tap `_isCheckingOut` lock (19595-19649).
2. **_showCheckoutDialog** (10033-10162): loads payment methods (cache -> Odoo -> hard fallback `نقدي`/`بطاقة`, 10063-10068; filtered by section `allowedPaymentMethodIds` 10076); delivery order types first require customer info dialog `_ensureDeliveryCustomerInfo` and, for "Delivery from company", a mandatory delivery-charge dialog (10088-10118); if a shipping company is selected shows `_CheckoutInfoDialog` (customer + driver, 10136-10161); then opens PaymentMethodDialog.
3. **PaymentMethodDialog**, `lib/features/pos/presentation/dialogs/payment_method_dialog.dart` (761 lines): 880px dialog supporting **split payments across methods** (list of `_PaymentEntry`, each with editable amount; tapping a method adds an entry pre-filled with the remaining amount, lines 103-110), customer-paid field + on-screen numeric keypad + quick-tender chips (exact total, 50/100/200/500/1000 filtered >= total, 153-164), remaining banner while `_paidSum < total`, change-owed banner `_changeToCustomer` (87-98), confirm enabled only when total covered (101), Enter/NumpadEnter shortcut (168-171), "تأكيد (Enter)" button. `_buildResult` (134-145) clamps recorded amounts to the order total (excess is change, never recorded), returning `[{id, name, amount}]`. Optional credit option (`showCreditOption`).
4. **Persist + receipt** (10437-11300): saves via `OfflineOrderService.saveOrderLocally` (offline-first; till owns the data), pushes pending sale to Firebase when online (skipped in demo), merges similar receipt lines (10884+), **auto-prints the cashier receipt** (11077+, `ReceiptPrintService`; comment "no KitchenReceiptScreen": `kitchen_receipt_screen.dart` (1805 lines) is a legacy preview/print screen no longer routed to), fire-and-forget sub-receipt printing to control printers (11242+), PDF fallback preview when silent printing fails (`_printReceiptPdfFallback`, 11815), clears the cart, logs audit "order checkout".

---

## 7. Orders management UI

### OrdersWithTabsScreen, `lib/features/orders/presentation/orders_with_tabs_screen.dart`
HomeScreen index 3. Tabs: "الطلبات" (`OrdersScreen`), "الطلبات السابقة" (`PastOrdersScreen`), admin-only "الجلسات المزامنة" (`SyncedSessionsScreen`). End-of-day tab is hidden (moved to settings). In Transaction mode it renders `ActivityLogsScreen` for today instead (lines 45-52).

### OrdersScreen, `lib/features/orders/presentation/orders_screen.dart`
Unified list of server (Odoo `OrderModel`) and local (`OfflineOrder`) orders (`_OrderListItem`); tap opens detail dialogs `_showServerOrderDetails` / `_showLocalOrderDetails` (lines 338-427).

### PastOrdersScreen, `lib/features/orders/presentation/past_orders_screen.dart` (2673 lines)
Firebase `sales` collection history with search, status filter (all/sale/cancelled), multi-select dialog. Order-details dialog offers **Cancel Order** ("إلغاء الطلب" with mandatory reason; non-admin requires manager approval; `cancelSaleInFirebaseByDocId`, lines 1449-1664) and **Reprint** (manager approval dialog, `_reprint` 2277+). This is the void/refund surface: cancellation with audit, no separate refund screen.

### SyncedSessionsScreen, `lib/features/orders/presentation/synced_sessions_screen.dart`
Pick a business date -> closed sessions count + orders grouped by sessionId (mirrors closing-report logic).

### EndOfDayClosingScreen, `lib/features/orders/presentation/end_of_day_closing_screen.dart` (1227 lines)
Day-close page: "تقفيل الجلسة" syncs pending Firebase orders to Odoo then renders a SUMMARY STATEMENTS report. (Hidden from tabs; reachable via settings/session flows.)

### SessionOrdersDialog, `lib/features/pos/presentation/session_orders_dialog.dart` (2232 lines)
Current-session orders dialog (opened from HomeScreen POS bar, PosModeShell chip, POS cart): realtime paginated list, payment-method name fixing, order edit action returning an edit result to POSScreen (loads cart with `_editingOrder`), delete with manager approval (fingerprint or PIN fallback, 2124+), print, and totals.

### SessionSyncScreen, `lib/features/pos/presentation/session_sync_screen.dart` (1075 lines)
Legacy/aux session sync UI with per-payment-method rows (read + edit) used in closing flows.

### Reports-side session screens
- `session_close_screen.dart` (reports sub-index 10): closes the active session, `onNavigateToTables` back-jump; uses `open_orders_manage_dialog.dart` (refresh/multi-select/delete `open_orders` docs).
- `current_session_payments_report_screen.dart` (sub-index 9): unsynced session orders with payment breakdown; also the "مدفوعات الجلسة" print target.

---

## 8. Kitchen UI, `lib/features/kitchen`

### KitchenDisplayScreen, `lib/features/kitchen/presentation/kitchen_display_screen.dart` (600 lines)
HomeScreen index 19. Fixed dark theme (bg #1A1D23, cards #242830), live clock, realtime Firestore order cards excluding cancelled/ready (lines 136-142). Each `_OrderCard` shows items and two actions: "start preparing" -> `kitchenStatus='preparing'` and "ready" -> `kitchenStatus='ready'` (lines 520-545); updates only `kitchenStatus`, never the sale status (line 53-57).

### Kitchen-related dialogs/widgets
- `dialogs/kitchen_preview_dialog.dart`: read-only items preview when no kitchen printer configured.
- `dialogs/kitchen_partial_error_dialog.dart`: lists failed printers + categories + reasons after a partial kitchen-send failure.
- `lib/widgets/kitchen_send_banner.dart`: global bottom banner for in-flight kitchen sends (yellow spinner / green tick auto-dismiss / red retry), mounted in MaterialApp.builder.
- `printer_routing_helper.dart`: category->printer routing result model.
- Kitchen update (diff) receipts on order edits (pos_screen.dart:13557+).

---

## 9. Kiosk + customer menu, `lib/features/kiosk`, `lib/features/menu`

### KioskScreen, `lib/features/kiosk/presentation/kiosk_screen.dart` (869 lines)
Self-order screen for a large touch display (43"), web `?mode=kiosk` or opened as a second window from PosModeShell. Phase state machine `_KioskPhase`: loading -> error('empty'/connection) -> **idle** (auto-playing splash image carousel; tap to start) -> **browsing** (reuses `CustomerMenuCatalogView` with a kiosk cart panel; product modifier dialog; 120s idle timeout resets) -> **confirm** (order number + countdown ~8s then back to idle). Submits to Firebase `menu_orders` stamped with branch/connection (`KioskContext`) via `FirebaseMenuService`.

### Menu (customer QR menu) screens
- `menu_splash_screen.dart`: `?mode=menu` entry; logo + loading + image carousel; `pushReplacement -> MenuMainScreen(catalog)` (lines 65-66).
- `menu_main_screen.dart`: categories/products/cart for customers; submit -> `push OrderStatusScreen` (lines 127-132); exit returns to splash (236-237).
- `customer_menu_catalog_view.dart`: shared light-theme catalog grid used by menu + kiosk (search, responsive grid, product tap callback, optional cart panel).
- `order_status_screen.dart`: live order status tracker with queue number.
- Admin-side menu tools (from Settings): `menu_sync_screen.dart` (Odoo -> Firebase menu sync), `menu_qr_print_screen.dart` (QR generate/print), `menu_media_screen.dart` (product image uploads), `menu_splash_settings_screen.dart` (carousel URLs), `menu_orders_screen.dart` (incoming menu/kiosk orders list; HomeScreen index 16; `menuOrderItemsToCartItems` converts an order into POS cart lines).

---

## 10. Customer display

- `customer_display_screen.dart` (in-app, HomeScreen index 12): promo slider on one side + live cart mirror on the other, fed by `CustomerDisplayService`.
- `customer_display_standalone_screen.dart`: separate browser window (`?mode=customer-display`, opened after login via `lib/utils/customer_display_window.dart`, web-only conditional import); reads Firestore `customer_display_basket/current`.
- `customer_display_slider_settings_screen.dart`: promo slider configuration (also in Settings menu).

---

## 11. Reports screens, `lib/features/reports/presentation`

- `reports_menu_screen.dart`: tile menu (HomeScreen reports sub-index 0) with entries (lines 163-352): Reports Dashboard, Items Sales, Orders Details, Discounts Report, Detailed Discounts, Audit Trail, Revenue Center, Tax Report, Expenses Report, Cost vs Sales, Comprehensive Analysis, Detailed Delivery Report, Delivery Reports (drivers), Cancelled & Modified Orders, Orders by Payment, ETA Invoices (wizard), ETA Invoice History, Current Session Payments; plus Flash section (lines 480-635): Flash Collector, Flash Summary, Delivery Flash, Today's Flash (combined or per waiter, prints immediately), Payment Method Flash, Previous Flashes; every flash requires a manager-confirmation dialog. Also hosts `session_close` entry.
- `reports_dashboard_screen.dart`: KPI dashboard (also RM default home).
- Standalone report screens (each with `onBackPressed` back to menu): `detail_orders_report_screen.dart`, `items_sales_report_screen.dart`, `discounts_report_screen.dart`, `detailed_discounts_report_screen.dart`, `expense_report_screen.dart`, `cost_vs_sales_report_screen.dart`, `delivery_report_screen.dart`, `delivery_report_drivers_screen.dart` -> `driver_delivery_report_screen.dart` (per-driver cards + orders table + detailed/short print), `current_session_payments_report_screen.dart`, `session_close_screen.dart`, `tax_report_screen.dart`, `revenue_center_report_screen.dart`, `audit_trail_report_screen.dart`, `cancelled_modified_orders_report_screen.dart` (All/Cancelled/Modified pills), `flash_report_screen.dart`, `menu_engineering_screen.dart` (star/workhorse/puzzle/dog matrix; HomeScreen index 17), `daily_stock_screen.dart` (index 22, read-only stock-count vs sales) + `daily_stock_reconcile_dialog.dart` (manager daily stock entry after login/sync; closing mode variant), `eta_invoice_wizard.dart` + `eta_invoice_history_screen.dart` (Egyptian ETA e-invoicing).
- `analytics_menu_screen.dart` (sub-index 4) -> 8 analytics screens in `analytics/`: top products, category performance, sales by time, sales by day, cashier performance, period comparison, modifier analysis, payment analysis (shared `analytics_report_mixin.dart`, `analytics_shared.dart` for date filter/chart/print).
- `advanced_analytics_screen.dart` (index 21).
- Shared widgets: `widgets/period_selection_dialog.dart` (daily/weekly/monthly/yearly + shift filter used across reports), `widgets/open_orders_manage_dialog.dart`, RM theming wrappers (section 3).

---

## 12. Settings screens (names only; depth covered elsewhere)

`settings_menu_screen.dart` (HomeScreen index 7) is a two-pane menu; on narrow screens it pushes the selected page as a route (line 726). Groups/entries (builders at lines 121-495): PrintersSettingsScreen, PrintersManagementScreen (also index 8), PrintDiagnosticsScreen, DiscountTypesSettingsScreen, ModifierSkipRulesScreen, QuickCommentsSettingsScreen, PricelistManagementScreen, MallSalesSettingsScreen, _StylingSettingsScreen (in-file; cart style, products layout, grid size, menu position, category colors link), CategoryColorsScreen, CustomerDisplaySliderSettingsScreen, TablesManagementScreen, MenuSyncScreen, MenuQrPrintScreen, MenuSplashSettingsScreen, CustomCategoriesScreen, MenuMediaScreen, ProductGroupsSettingsScreen, DriversScreen, ShippingCompaniesScreen, ShippingZonesScreen, OdooSyncSettingsScreen, EmailReportSettingsScreen, WhatsAppReportSettingsScreen, EtaSettingsScreen, EtaAccessManagementScreen, _DatabaseSyncSettingsScreen (in-file), _BackupScreen (in-file), UsersManagementScreen, TotpSetupScreen, RolesAccessScreen, AttendanceScreen, AttendanceRegistrationScreen, FirebaseProjectSettingsScreen, ShiftSettingsScreen, TableSecuritySettingsScreen, BranchManagementScreen, AiSettingsScreen, AuditLogScreen, OrderSyncDiagnosticsScreen, OpenOrdersScreen, SessionOverrideScreen, ServerSettingsScreen, ActivityLogsScreen, MergeSessionsScreen, AboutScreen. Helpers: `access_control_defs.dart`, `inline_keypad.dart`, `secure_delete_dialog.dart`.

---

## 13. Other feature screens

- **Customers**: `customers_screen.dart` (index 4): Odoo customer list/search/add-edit.
- **Products**: `products_screen.dart` (index 2), `product_edit_screen.dart` (responsive 1/2-column edit form via `/api/product/update`), `general_additions_screen.dart` (tabbed extras manager).
- **Categories**: `custom_categories_screen.dart` (custom POS category groupings; from Settings).
- **Coupons**: `coupons_screen.dart` (index 20, dark themed, tabbed).
- **Loyalty**: `loyalty_settings_screen.dart` (index 18).
- **Expenses**: `expenses_screen.dart` (index 6, record/list expenses).
- **Warehouse**: `warehouse_order_screen.dart` (index 14, order-from-warehouse requests).
- **Delivery/shipping (active)**: `shipping/presentation/delivery_orders_screen.dart` (index 15 and PosModeShell delivery lists; filters all/unassigned/assigned, driver assignment per order, `deliveryTypeFilter`, `currentSessionOnly`, `disableDriverAssignment`), `drivers_screen.dart`, `shipping_drivers_screen.dart`, `shipping_companies_screen.dart`, `shipping_zones_screen.dart`.
- **Delivery (orphaned)**: `delivery/presentation/delivery_orders_screen.dart` + `delivery_order_detail_screen.dart` (print receipt): not referenced by any live route; superseded by the shipping version.
- **Attendance**: `attendance_screen.dart` (daily fingerprint attendance board, polling check-in/out), `attendance_registration_screen.dart` (admin enrolls >=3 fingerprint templates), `cashier_attendance_screen.dart` (admin grid of cashier tiles, opened from the tables board via `CashierAttendanceScreen.show`).
- **Shared overlay widgets** (`lib/widgets/`): `ai_chat_popup.dart` (AI assistant overlay from sidebar; can trigger nav actions like open_reports/open_pos via `_handleAiAction`, home_screen.dart:3520-3541), `quick_search_overlay.dart` (Ctrl+K), `smart_alerts_widget.dart` (dashboard alerts), `fingerprint_dialog.dart` + `fingerprint_verify_button.dart`, `admin_totp_dialog.dart`, `force_logout_progress_screen.dart`, `virtual_keyboard.dart`, `pos_text_input.dart`, brand widgets in `widgets/brand/`.

---

## 14. Encoded journeys (integration tests)

### Login journey, `integration_test/login_pin_journey_test.dart`
Drives the real `LoginScreen` + real `PinPad` against fake Firestore (`pos_users` doc with `quickLoginEnabled`, hashed PIN 8899) and a seeded offline Odoo login cache. Sequence: LoginScreen detects quick-login users -> fingerprint agent unreachable -> PIN mode ("دخول بـ PIN") -> tap digits -> "دخول" submit -> PIN hash match -> `OdooApiService.login(allowOfflineLogin:true)` offline fallback -> navigates off LoginScreen to **SyncScreen** (first authenticated screen), which then auto-advances to **HomeScreen** (test accepts either). Wrong PIN: inline error "PIN غير صحيح — حاول مجدداً", stays on LoginScreen.

### Happy-path ordering, `integration_test/pos_ordering_journey_test.dart` (skip:true due to un-seamed Firestore listeners; assertions verified on passing runs)
`POSScreen(useDemoMode:true)` in a Scaffold: tap product "قهوة أمريكية" (15.0) twice -> qty badge "2"; on-screen subtotal/tax(14%)/total recompute live in `ج.م`; add "كابتشينو" (18.0); decrement coffee via `Iconsax.minus` (direct, no dialog above qty 1); remove cappuccino (qty1 minus removes line); tap **"ادفع"** -> payment-mode dialog -> **"دفع كامل"** -> `PaymentMethodDialog` -> tap method **"نقدي"** (assigns full remaining amount) -> **"تأكيد (Enter)"** -> cart cleared; order persisted by `OfflineOrderService.getOfflineOrders()` with 1 line + payments summing to total. (In the full app this is preceded by login and, with tables enabled, table + guest-count selection, and followed by auto receipt print.)

### Split payment edge, `integration_test/pos_split_payment_edge_test.dart` (skip:true, same infra reason)
(a) Split: pizza 45.0 -> total 51.30; enter 30 in amount field, tap "نقدي", remaining banner shows 21.30, tap "بطاقة" for the rest, confirm; order has 2 payment entries summing to total. (b) Overpay: tender 100 cash for 51.30 -> change banner shows 48.70 (`_changeToCustomer`, payment_method_dialog.dart:88-98); recorded payment clamped to the order total (`_buildResult`, lines 134-145).

---

## 15. Theme, localization, form factor

- **Theme** `lib/core/theme/app_theme.dart`: Material 3 light + dark themes built from `lib/core/constants/app_colors.dart` (primary/secondary/error/surface/background pairs, background gradients), Cairo font via `lib/core/utils/font_helper.dart`, rounded 14-16px inputs/cards/buttons. `theme_provider.dart`: `ThemeProvider` ChangeNotifier persisting dark mode; toggled from HomeScreen sidebar; RM shell forces its own light theme (`RmLightDashboardTheme`). Many operational screens (KDS, coupons) hardcode a dark palette. `ThemeColors(isDark:)` helper struct is passed around widely.
- **Localization**: no ARB/intl codegen; `lib/core/localization/locale_provider.dart` persists `ar`/`en` (default **ar**), `tr_extension.dart` gives `context.tr('عربي','English')` inline pairs, `app_strings.dart` holds a small keyed set. RTL: `MaterialApp.builder` wraps the whole app in `Directionality(rtl when Arabic)` (main.dart:305-306). Language toggles live on ModeSelection, HomeScreen sidebar, RM sidebar. Currency/tax in `lib/core/constants/app_locale.dart`: `ج.م`/EGP, 14% tax.
- **Form factor**: landscape-locked (main.dart:245-248); designed for desktop/web/tablet tills. Tablet/iPad support via launch scripts (`launch_tablet.sh`, `launch_ipad_10inch.sh`, `run_ipad_landscape.sh`, `setup_ipad_simulator.sh`, `create_tablet_emulator.sh`). In-app adaptations are width-based rather than platform-based: POS cart width clamps (pos_screen.dart:13723-13736), RM shell switches sidebar->drawer under 900px (rm_mode_shell.dart:78), HomeScreen offers a bottom-nav layout via the `menu_position` setting (home_screen.dart:2004-2011) suited to smaller screens, settings menu pushes detail pages as routes when narrow (settings_menu_screen.dart:726), product grid size S/M/L toggle, sidebar auto-collapse on POS. PosModeShell checks `TargetPlatform.iOS` for minor tweaks (pos_mode_shell.dart:1859).

---

## 16. Screen-to-screen navigation quick map (primary edges)

```
main._getInitialScreen
 ├─ (web ?mode=) CustomerDisplayStandalone / MenuSplash→MenuMain→OrderStatus / Kiosk(idle→browse→confirm) / Home(demo) / OrderSyncDiagnostics / RmWebLogin→RmWebBranchSelection→RmModeShell
 └─ SplashScreen
     ├─ ModeSelectionScreen ──(pick mode)──► LoginScreen
     ├─ FirebaseCheckScreen ──► SyncScreen | LoginScreen | ServerValidationScreen | FirebaseProjectSettingsScreen
     ├─ LoginScreen ──(PIN/fingerprint/classic)──► SyncScreen ──► HomeScreen | PosModeShell | RmModeShell | TransactionModeShell
     │        └─(server icon)──► ServerSetupScreen ──► LoginScreen
     └─ (already logged in) HomeScreen | PosModeShell | RmModeShell | TransactionModeShell

HomeScreen[index]: 0 Dashboard · 1 TableReservation/POSScreen · 2 Products · 3 OrdersWithTabs(Orders|Past|SyncedSessions) · 4 Customers · 5 ReportsMenu→{Dashboard,DetailOrders,ItemsSales,AnalyticsMenu→8 reports,Discounts,Expense,CostVsSales,DeliveryReport,SessionPayments,SessionClose,DriverReports} · 6 Expenses · 7 SettingsMenu→~45 settings screens · 8 Printers · 12 CustomerDisplay · 14 Warehouse · 15 DeliveryOrders · 16 MenuOrders(→load cart→POS) · 17 MenuEngineering · 18 Loyalty · 19 KDS · 20 Coupons · 21 AdvancedAnalytics · 22 DailyStock

POS sell: TableReservation ─(table→CashierSelection→GuestCount)─► POSScreen
 POSScreen: product tap→cart · modifiers(ProductModifierScreen dialog / UnitModifiersSelector) · note bottom-sheet · discount(auth dialog→discount dialog) · order-type dropdown · suspend/resume · send-to-kitchen(preview/partial-error dialogs)
 checkout: إتمام الطلب → _PaymentModeDialog{full|partial(_MoveItemsSelectionDialog)|split_people(_SplitByPeoplePaymentDialog)|pay_guest} → (delivery info / _CheckoutInfoDialog) → PaymentMethodDialog(split methods, tender, change) → save offline (+Firebase) → auto-print receipt → cart cleared

Force logout (any screen) → ForceLogoutProgressScreen → ModeSelectionScreen
Logout (HomeScreen) → _LogoutRedirect → ModeSelectionScreen; PosModeShell logout gated by admin PIN/fingerprint
```


---

# DETAILED FINDINGS: Dishflow POS: Settings + Configuration Surface Inventory

# Dishflow POS: Settings + Configuration Surface Inventory

Repo: `/home/username/workspace/Dishflow-pos` (branch `Test`). App version `2.7.5` (`pubspec.yaml:14`). All paths below are relative to repo root unless absolute.

---

## 1. Settings entry point / architecture

- `lib/features/settings/presentation/settings_menu_screen.dart` (1548 lines): master-detail settings hub with collapsible sidebar groups. Groups and items built in `_buildGroups()` (lines 106-501).
- Visibility gating: `Tables` group only if `FirebasePermissionService().canManageTables` (line 107/210); `Users & Permissions`, `Fingerprint & Attendance`, and the whole `System` group only if `role == 'admin'` (line 108/354).
- Two storage tiers used throughout: **SharedPreferences** (device-local cache/first paint) and **Firestore** (authoritative, shared across terminals). Most services load prefs first then overwrite from Firestore.

### Sidebar groups and items (ids from `_buildGroups`)
| Group | Items (id) |
|---|---|
| Printing | printers_settings, printers_management, print_diagnostics |
| Sales | discounts, modifier_skip, quick_comments, pricelists, mall_sales |
| Appearance | styling, category_colors, customer_display (ads slider) |
| Tables (perm-gated) | tables |
| Menu | menu_sync, menu_qr, menu_splash, categories, menu_media, product_groups |
| Delivery | delivery_drivers, delivery_companies, delivery_zones |
| Sync & Reports | odoo_sync, email_report, whatsapp_report, eta_settings, eta_access, db_sync, backup |
| Users & Permissions (admin) | users, totp, roles_access |
| Fingerprint & Attendance (admin) | fingerprint_attendance, fingerprint_registration |
| System (admin) | firebase, shift, table_security, branches, ai, audit_log, order_sync_diagnostics, open_orders, session_override, server_settings, server_activity_log, merge_sessions, about |

---

## 2. Appearance / Styling settings (`_StylingSettingsScreen`, settings_menu_screen.dart:834-1410)

All persisted via `lib/services/local_storage_service.dart`, dual-written to SharedPreferences AND Firestore `settings/app_config` (see LocalStorageService lines 1082-1283 which read Firestore fallbacks). Defaults from local_storage_service.dart:

| Setting | Type/options | Key (prefs / Firestore field) | Default | Behaviour |
|---|---|---|---|---|
| Cart Style | 'modern' \| 'classic' | `cart_style` / `cartStyle` | 'classic' | Cart rendering: cards vs table columns |
| Products Layout | 'top' \| 'side' | `products_layout` / `productsLayout` | 'top' | Category strip horizontal above grid vs vertical side |
| Product Card Style | 'grid' \| 'list' \| 'compact' | `product_card_style` / `productCardStyle` | 'grid' | Product tile rendering |
| Menu Navigation | 'left' \| 'bottom' | `menu_position` / `menuPosition` | 'left' | Sidebar vs bottom nav |
| Table Sections Layout | 'top' \| 'side' | `table_sections_layout` / `tableSectionsLayout` | 'top' | Tabs above tables vs side list |
| Customer Display enabled | bool switch | `customer_display_enabled` / `customerDisplayEnabled` | true | Opens customer-facing display window showing cart |
| Kiosk enabled | bool switch | `kiosk_enabled` / `kioskEnabled` | false | Shows "Kiosk Screen" button + customer order alerts; kiosk URL is `?mode=kiosk` |
| Category colors & style | link to CategoryColorsScreen | see section 3 | | |

Also in LocalStorageService (device-local only unless noted):
- `pos_grid_size` (string) product grid size, also synced per Odoo connection to Firestore collection `ui_settings/{connectionId}.grid_size` (`lib/services/firebase_ui_settings_service.dart:18,54`).
- `tables_count` int, default 10, clamped 1-99 (local_storage_service.dart:208-213).
- Table state colors: `table_color_available` (default 0xFF22C55E), `table_color_occupied` (0xFFEF4444), `table_color_suspended` (0xFFFBBF24), `table_color_reserved` (0xFF3B82F6) (lines 72-75, 1310-1313); edited from `lib/features/pos/presentation/table_reservation_screen.dart`.
- `pos_machine_id` auto-generated machine id (line 53).

### Category colors screen (`category_colors_screen.dart`, 751 lines)
Backed by `lib/services/category_appearance_service.dart`; prefs keys + Firestore `settings/category_appearance`:
- Per-category color overrides: `category_colors` (by id) + `category_colors_by_name`.
- Chip shape: `category_chip_shape`, default 'rounded'.
- Show product count badge: `category_show_count`, default true.
- Chip height: `category_chip_height`, double, default 36.0.
- Category font size: `category_font_size`, default 12.0.
- Text alignment: `category_text_align`, 'right'/'center'/'left', default 'center'.
- Reset-all action.

### Theme / dark mode
- `lib/core/theme/theme_provider.dart`: prefs key `is_dark_mode`, **default true (dark)**; `toggleTheme()`/`setDark()`.

### Localization
- `lib/core/localization/locale_provider.dart`: languages **Arabic ('ar', default) and English ('en')** only; prefs key `app_locale`; `toggle()` flips ar/en. `tr_extension.dart` provides `context.tr(ar, en)`; `app_strings.dart` is the string table. Currency is NOT configurable: hardcoded `lib/core/constants/app_locale.dart:6-9` (`ج.م` Arabic / `EGP` English).

### Customer Display Ads (`lib/features/pos/presentation/customer_display_slider_settings_screen.dart`)
- List of ad image URLs for the customer display slider; saved via Firestore (add/remove link rows, save).

---

## 3. Printing configuration

### 3a. Printer Settings screen (`printers_settings_screen.dart`, 2602 lines)
- **Default Printers**: default kitchen printers (multi), main receipt printer, sub receipt printer, delivery printer. Local keys `default_receipt_printer_id`, `default_sub_receipt_printer_id`, `default_delivery_printer_id` (local_storage_service.dart:59-61).
- **Category Printers**: per product-category assignment stored as `PrinterSettingsModel` list, prefs key `printer_settings` (fields per `lib/features/settings/data/models/printer_settings_model.dart`: category_id, category_name, kitchen_printer (legacy single), kitchen_printers (multi, fan-out to ALL), receipt_printer, sub_receipt_printer/sub_receipt_printers (no-price copy for customer/driver), delivery_receipt_printer). "Apply to All Categories" bulk action.
- **Product Printers**: per-product overrides, prefs key `printer_settings_products` (line 34); search, "assigned only" filter, PDF export of assignments, clear per-product.
- **Print Agent URL**: per-device IP field with fixed `:9199` suffix (printers_settings_screen.dart:66,107,1366-1449); prefs key `print_agent_url`, default `http://127.0.0.1:9199` (local_storage_service.dart:674). Legacy agent toggle key `legacy_agent_enabled`, default false (line 658).
- Cloud copy of printer config: Firestore collection `printer_settings`, doc `global` (+ per-user docs) via `lib/services/firebase_printer_service.dart:14-15,229`.
- Receipt template selection per receipt type (main/sub/delivery): `lib/features/settings/data/models/receipt_template.dart` ids `classic` (default), `classic_modern`, `cai`, `compact`; prefs keys `receipt_template_main|sub|delivery` (default 'classic', local_storage_service.dart:908-928); synced to Firestore `receipt_templates/{odooConnectionId}` (`firebase_receipt_service.dart:67,82`).
- Receipt font-size profiles per receipt type: `receipt_font_sizes_main|sub|delivery`; model `receipt_font_sizes.dart`: 6 elements (header, section, itemName, qty, price, total) x presets default/xs(1x1)/sm(1x2)/md(2x2)/lg(2x3)/xl(3x3)/xxl(4x4) mapping to ESC/POS `GS ! n`; default 'default' (= v2.6.1 look).

### 3b. Printer Management screen (`printers_management_screen.dart`, 2270 lines)
Printer CRUD, stored locally under prefs key `printers` (list of `PrinterModel`, `lib/features/settings/data/models/printer_model.dart`):
- Fields: id, name, **type: 'kitchen' | 'receipt' | 'delivery'**, ip_address, port, is_connected, last_tested.
- Per-printer toggles: **Skip Modifiers** (strip modifier lines, for cashier/receipt printers), **Group Modifiers** (dedupe to "2x ..."), **Fallback printer** (auto-retry unreachable printer on the fallback id).
- Actions: network scan ("🔍 فحص الشبكة" discovery, "printers only" filter, add discovered device), TCP connection test, test print, **open cash drawer** command, edit, delete. Warns "POSPrint is not running".
- Tab 2 "Assign Products": bulk product-to-printer assignment with select-all/save.

### 3c. Print routing (per terminal)
`lib/services/print_routing_service.dart`: Firestore doc `settings/print_routing` keyed by terminal name holding `{primary, backup}` receipt printer ids; terminal identity in prefs `pos_terminal_name` / `pos_terminal_id`. Shared by all terminals; job metadata includes user_name/shift/primary/backup (lines 193-201).

### 3d. Print Diagnostics screen (`print_diagnostics_screen.dart`, 1887 lines)
Read-only diagnostics: mesh node status, printer health, print flow tracing.

### 3e. POSPrint mesh agent (`pos_print_mesh/`)
Compiled Dart Windows binary POSPrint.exe replacing 6 legacy agents. Config file `pos_print_mesh.json` (repo copy: project_id `pos-test-70970`, branch_id "", collection `print_jobs`, firebase_api_key, emulator_host, poll_ms 2000, heartbeat_ms 5000, http_port 9199, max_retries 5, retry_delay_ms 15000, claim_timeout_ms 60000, printers[] with name/ip/port/role kitchen|receipt). First-run wizard asks project id, branch id, emulator host, printers (subnet auto-scan). README field reference at `pos_print_mesh/README.md`.
- Agents heartbeat to Firestore `agent_heartbeat/{nodeId}` every 5s incl. LAN IPs and http_port (default 9199) and printer health; the app auto-discovers agents via `lib/services/agent_discovery_service.dart` (prefers agent with healthy printer of required role). Hardcoded fallback `lib/services/print_agent_service.dart:10` `http://127.0.0.1:9199`.

### 3f. Legacy Node print agent (`print_agent_setup/`)
`print_agent.js` + installer. User config `print_agent_config.default.json`: `queue_enabled` true, `queue_max_size` 5000, `queue_max_attempts` 5, `fallback_enabled` false, `health_monitor_enabled` false, `disable_auto_update` false, `printers` [] (name/ip/port/fallback_group). Auto-update manifest `latest.json` (v2.9.0, hosted at adminblkan-madentnasser.code-solution.org). Release notes 2.6.4-2.7.2 in same dir.

### 3g. ZK fingerprint agent
`zk_fingerprint_agent.py` + `start_zk_agent.bat`: local Flask agent on **port 9201** for ZK8500R fingerprint reader (ports 9199/9200 reserved for print agent). Used by attendance screens.

---

## 4. Sales settings

### Discount Types (`discount_types_settings_screen.dart`, 465 lines)
- CRUD list of percentage discount types (1-100%), reset-to-default action.
- Toggle **"Allow amount discount"** (fixed-amount discounts), prefs key `allow_amount_discount`, default false (local_storage_service.dart:225).
- Local storage `discount_types` + Firestore collection `discounts/{odooConnectionId}` (`firebase_discount_types_service.dart:21,36`).

### Modifier Skip Rules (`modifier_skip_rules_screen.dart`, 441 lines)
Per product, per modifier option: **Skip Next** (choosing this option skips subsequent modifier groups) and **Hide** (option hidden in POS for that product). Also shows options "set to skip in Odoo". Stored Firestore `modifier_option_overrides/{connectionId}` (`modifier_option_overrides_service.dart:56,117`).

### Quick Comments (`quick_comments_settings_screen.dart`, 274 lines)
CRUD of predefined kitchen note strings (e.g. "no onion"). Firestore collection `quick_comments` (`firebase_quick_comments_service.dart:36`).

### Pricelists (`pricelist_management_screen.dart`, 2402 lines)
Create/edit/duplicate/delete pricelists; per-pricelist flags default/active; per-product price editor with bulk percentage adjust; CSV export/import; assignment to branches (Firestore `pricelists` collection + `branches` doc update, `pricelist_service.dart:26,104,245`).

### Mall Sales % (`mall_sales_settings_screen.dart`, 431 lines)
- **Percentage (0-100)** applied to gross for mall commission reporting; prefs key `mall_sales_percentage` + Firestore `settings/mall_sales.percentage` (`mall_sales_settings_service.dart:15-17`, default 0.0).
- Per payment-method **Flash ON/OFF** toggles (exclude payment methods from flash report), stored on docs in Firestore collection `payment_methods` (screen lines 44,120).

---

## 5. Sync & Reports settings

### Odoo Sync (`odoo_sync_settings_screen.dart`, 536 lines; `odoo_sync_settings_service.dart`)
- **Session report customer**: default Odoo partner (search/select/change/clear) that session-close orders are booked to; empty = each order's original customer. Keys `odoo_sync_partner_id`/`odoo_sync_partner_name` + Firestore `settings/odoo_sync.defaultPartnerId/defaultPartnerName`.
- **Invoice Mode**: "Single Consolidated Invoice" toggle (`odoo_sync_consolidated`, default false) vs separate invoices.

### Database Sync (inline `_DatabaseSyncSettingsScreen`, settings_menu_screen.dart:1412-1547)
- **Auto Sync** toggle: sync every 30 minutes (via `PosApiService.get/setAutoSyncEnabled`).
- Manual triggers: Sync Products, Sync Categories, Push Orders to Odoo, Full Sync.

### Export Backup (inline `_BackupScreen`, settings_menu_screen.dart:745-816)
One-button local backup export via `BackupService().exportBackup()`.

### Email Session Report (`email_report_settings_screen.dart`, 580 lines; `email_report_settings_service.dart`)
- Enable toggle (`email_report_enabled`, default false).
- Sender account: email, password, sender name.
- SMTP: host (default `mail.code-solution.org`), port (default 465), SSL (default true).
- Recipients list (add/remove, validated).
- Stored prefs keys `email_report_*` + Firestore `settings/email_report`.

### WhatsApp Session Report (`whatsapp_report_settings_screen.dart`, 495 lines; `whatsapp_report_settings_service.dart`)
- Enable toggle (`wa_report_enabled`, default false).
- WAAPI credentials: app key (default `fed30203-...` baked in), auth key, endpoint base URL (defaults baked in service lines 26-29).
- Recipient phone numbers list.
- Stored prefs `wa_report_*` + Firestore `settings/whatsapp_report`.

### ETA E-Invoice (Egypt Tax Authority) (`eta_settings_screen.dart`, 1381 lines; `lib/services/eta_service.dart`)
- **Environment**: Production vs Sandbox radio + save (URLs hardcoded eta_service.dart:122-126; prefs mirror `eta_use_sandbox`).
- **Company info**: Tax ID (RIN), trade name, activity code.
- **Tax-only Reports toggle**: past-day reports show only ETA-submitted orders (today's session stays full).
- **Integrations list** (multi-branch POS credentials): per integration name, Client ID, Client Secret (obscured), serial number, branch code, address (governate, region/city, street, building number); add/edit/delete.
- **Export products** (ETA item catalog export; requires RIN + synced products).
- Stored Firestore `settings/eta_integration`; default integration mirrored to prefs `eta_client_id/secret/serial_number` (eta_service.dart:369-372).

### ETA Invoice Access (`eta_access_management_screen.dart`, 360 lines)
Email whitelist for viewing ETA invoices; bulk add emails, send/resend access codes, remove. Stored Firestore `settings/eta_access_codes` (`eta_access_service.dart:15-16`).

---

## 6. System settings (admin only)

### Firebase Project (`firebase_project_settings_screen.dart`, 313 lines)
Paste raw `firebaseConfig` JSON (apiKey/authDomain/projectId/storageBucket/messagingSenderId/appId) to point the terminal at a different Firebase project (multi-tenant switch); validate + save via `FirebaseConfigService`, reset-to-default (built-in config); requires app restart. Legacy key `firebase_selected_project_id` (`firebase_project_service.dart:10`).

### Shift Settings (`shift_settings_screen.dart`, 207 lines; `firebase_shift_service.dart`)
- Morning shift start hour and end hour (0-23 ints). Defaults **6 -> 14** (service lines 16-17). Evening shift is implicit (end -> next start). Drives business-date derivation (before start hour counts as yesterday). Stored Firestore `settings/app_config.morningShiftStart/morningShiftEnd`. Save logs `shift_settings_updated` to activity log.

### Table Security (`table_security_settings_screen.dart`, 158 lines; `lib/services/pos_behavior_settings_service.dart`)
Firestore `settings/pos_behavior` + prefs cache. Fields (service lines 19-36):
- `pos_require_password_to_open_table` bool, **default true**: PIN/password on table tap; occupied table resumable only by owner or admin; new table only for checked-in users.
- `pos_require_cashier_reentry_verification` bool, default false.
- `pos_hide_cancel_order_button` bool, default false (toggled elsewhere, service-level knob).
- `pos_show_stock_button` bool, default true.

### Branch Management (`branch_management_screen.dart`, 1870 lines)
Branch CRUD via POS backend REST (`pos_api_service.dart` /branches endpoints): name, active/inactive toggle, delete, member management (add/remove users per branch), pagination/filter.

### AI Assistant (`ai_settings_screen.dart`, 517 lines; `ai_chat_service.dart`)
- AI Agent server URL (prefs `ai_agent_base_url`, default `http://164.68.100.86:9200`), test connection.
- Model picker (fetched from server; prefs `ai_agent_model`).
- Gemini API key save/remove (prefs `ai_gemini_api_key`, also pushed to the agent server); provider badge ollama vs gemini.

### Server Settings (PostgreSQL backend) (`server_settings_screen.dart`, 407 lines; `server_config_service.dart`, `pos_api_service.dart`)
- Backend base URL (default `http://localhost:8000/api`, prefs `pos_api_base_url`), save + ping.
- Login email/password to obtain JWT (used by audit-log upload etc.); logout.
- URL and last email are shared cross-device via Firestore doc `app_config/pos_server` (fields cached in prefs `pos_server_base_url_cloud`, `pos_server_login_email_cloud`).

### Session Override (`session_override_screen.dart`, 686 lines)
Local-only repair tool: view current session id / business date / shift; set a **frozen session id** (prefs `frozen_session_id`, `frozen_business_date_key`, `frozen_shift`), "Use Canonical ID", clear local session; view/clear local cashier shift blob (prefs `active_cashier_shift`).

### Merge Sessions (`merge_sessions_screen.dart`, 698 lines)
Admin tool to merge two session ids' sales data (Firestore session adjustment via `firebase_session_adjustment_service.dart`).

### Open Orders (`open_orders_screen.dart`, 823 lines)
Manage Firestore `open_orders` collection: view all, edit, mark paid, delete individually or clear all.

### Order Sync Diagnostics (`order_sync_diagnostics_screen.dart`, 527 lines)
100% offline diagnostics of locally cached orders vs sync flags; can edit `serverOrderName` per order.

### Activity Log (`audit_log_screen.dart`, 840 lines)
Firestore-backed activity log with date+time range, category/user filters, CSV download, auto-cleanup. Writer: `lib/services/activity_logger_service.dart` (settings changes log actions like `shift_settings_updated`, `server_url_changed`, `ai_model_changed`).

### Activity Log Server (`activity_logs_screen.dart`, 1348 lines)
Viewer for server-side (PostgreSQL backend) activity logs: search, category filter, pagination, details modal.

### About (`about_screen.dart`, 196 lines)
Company name, logo, app version + build number from package info.

---

## 7. Users, roles, permissions, PIN

### Permission system core: `lib/services/firebase_permission_service.dart`
- Per-user doc in Firestore `pos_users/{odooUserId}`: `role`, `permissions[]`, `allowedScreens[]`, `allowedOrderTypes[]`, `allowedModes[]`, `allowedRmReports[]`, `allowedPosFeatures[]`, `branchId`, `branchName`, `name`, `isBlocked`, plus quick-login fields (below). Empty list = allow-all (backward compatible).
- `UserScope` (lines 87-185): user-scoped state written atomically (`_apply`, line 214) to prevent cross-user leakage on shared terminals. `UserScope.denied()` = viewer+blocked; unknown user gets `['view_dashboard','view_orders']` viewer access (line 125-131).
- Local cache blob prefs key `firebase_permissions` stamped with `ownerUserId`; `cacheBelongsTo` (line 204) refuses another user's cache; unstamped legacy blobs accepted.
- **Last commit `b84dc64` "fix(permissions): release the connection lock when denying access"**: `_denyAccess()` (lines 230-236) now also sets `_connectionLocked = false`. `_connectionLocked` (line 346) is set by the RM web flow after branch selection so report screens cannot reset the active connection; without the fix a later normal login stayed pinned to the RM branch connection. Related commits: `7c66803` deny-before-restore, `e1d7df5` owner stamp kept, `535c209` single-set write, `581f47b` tests.
- Permission read timeout 10s (line 196); fallback to local cache on failure.
- Permission getters (lines 377-426): view_dashboard/pos/products/orders/customers/reports/expenses/settings/prices/menu_engineering/loyalty/kds/coupons/advanced_analytics/eta_invoices; create_order, edit_order, cancel_order, apply_discount, create_expense, edit_products, sync_data, print_flash_report, close_session; manage_users/tables/loyalty/coupons, use_tables. Special-cases: `canApplyDiscount` = admin OR (perm AND app-level allowDiscounts); `canViewPrices` = perm AND showPrices; ETA invoices and flash report also granted to role admin/manager.
- Odoo connection resolution: Firestore collection `odoo_connections` (doc: name, url, database, isActive, subscriptionStart/End; `isSubscriptionValid` unlimited if unset) (lines 10-77, 493-560).
- App-level settings read from `settings/app_config` in `_loadAppSettings()` (lines 614-639): `odooUrl`, `maintenanceMode` (false), `maintenanceMessage`, `showPrices` (true), `allowDiscounts` (true), `allowOfflineMode` (true), `tableSelectionEnabled` (true), `hideSendToKitchenButton` (**default true = hidden**), `dailyStockEnabled` (default false, master switch for stock count/sales-ratio feature), `cartStyle`.

### Permission catalog: `lib/features/settings/presentation/access_control_defs.dart`
- `kAccessScreens` (line 16): 17 screens + 4 POS header elements (dashboard, pos, products, orders, warehouse_order, customers, reports, expenses, settings, zones, shipping_companies, categories, menu_engineering, loyalty, kds, coupons, advanced_analytics, delivery_orders_store, delivery_orders_company, table_stat_available, table_stat_occupied).
- `kPermissionGroups` (line 62): Views (15), Actions (9), Management (5) as listed above.
- `kAppModes` (line 113): pos, delivery, admin, rm, transaction.
- `kOrderTypes` (line 121): Dine-in, Takeaway, Delivery from company, Store delivery, Car delivery.
- `kPosFeatures` (line 132): 15 POS UI elements gateable per user (toolbar logout/flash/transfer-table/session-orders, suspend, order-type selector, tables+guests, discount button, send-kitchen, print buttons, multicart tabs, move items, clear cart, delivery buttons, edit product from POS).
- `kRmReports` (line 154): RM-mode report permissions: 13 sales reports (item sales, order details, flash, session payments, discounts, detailed discounts, revenue centers, tax report, cost vs sales, expenses, delivery, audit trail, ETA invoices), 8 analytics, 2 labor reports.
- `kRoleColors` (line 239): built-in roles admin, cashier, supervisor, accountant, kitchen, viewer, reviewer, delivery.

### Roles & Access screen (`roles_access_screen.dart`, 2844 lines)
Two top tabs: **Users** and **Roles**.
- Users tab: select user, 6 sub-tabs: Screens (allow-all toggle or per-screen checkboxes), Permissions (grant/revoke all, per-perm), Order Types (default-by-role or explicit set), RM Permissions, Modes, POS Elements; "Apply Role Template" copies a role's permission set; save writes `pos_users` doc.
- Roles tab: create/edit/delete custom roles (name, id, color from `kAvailableColors`); admin role cannot be deleted.
- Also hosts app-level toggle **"Enable Stock & Sales Ratio"** (dailyStockEnabled, screen line ~100).

### Users Management (`users_management_screen.dart`, 982 lines)
- Add new Odoo user (admin credential verification first): name, login, password, user type Internal vs Portal, default role, default warehouse (optional), allowed payment methods (empty = all); creates in Odoo + syncs to `pos_users`.
- Per-user: role assignment, Blocked toggle, permissions dialog save, quick-login indicator (`quickLoginEnabled`).

### Quick Login / PIN (`lib/services/quick_login_service.dart`)
- PIN login: 4-6 digits (consts lines 50-51), digits only; stored on `pos_users` doc as `pinHash` = SHA-256(salt||pin) + `pinSalt` (16B random), plus `odooPasswordEnc` (encrypted with app secret), `pinFailedAttempts`, `pinLockedUntil` lockout fields.
- Enable/disable per user writes/deletes those fields (lines 183-209).

### TOTP (`totp_setup_screen.dart`, 637 lines; `totp_service.dart`)
- Admin authenticator: issuer 'CairoCaizer POS', 6 digits, 30s period; setup flow QR + manual secret, verify & enable, re-setup, disable. Secret stored via FirebasePermissionService on the user record field `totp_secret` (firebase_permission_service.dart:1060-1064).
- Used by `secure_delete_dialog.dart` (1150 lines): destructive deletions require confirmation + admin password OR TOTP token.

---

## 8. Business / tenant configuration

### Per-tenant Firebase configs: `lib/firebase_configs/*/firebase_options.dart` (14 dirs)
Each dir contains ONLY a `firebase_options.dart`; **the only thing that varies is the Firebase project credentials** (apiKey/appId/messagingSenderId/projectId/authDomain/storageBucket/measurementId per platform). All branding/feature/tax/receipt config lives inside each tenant's own Firestore, not in code. Mapping (dir -> projectId):
- balkans_madente -> balkans-madente
- balkanz_gym -> pos-juma (Balkanz Gym)
- balkanz_nasr -> pos-test-70970 (Balkanz Nasr City)
- balkanz_zayed -> zayed-city-afdb2 (Balkanz Zayed)
- balkns_copy_live -> pos-test-70970 (copy)
- balkns_sahel_one -> balkns-sahel-brunch-one
- balkns_sahel_two -> balkns-sahel-brunch-tow
- cai_gardennasrcity -> cai-gardennasrcity
- cai_madenty -> pos-admin-dashboard-bf6d9 (Cairo Caizer Madinaty)
- cai_sahel_one -> cai-sahel-brunch-one
- cai_sahel_two -> cai-shel-brunch-tow
- cai_sawspark -> cai-sawspark-madinte
- cai_straubmall -> cai-straub-mall
- dev -> odc-chat (Dev/Test)
Active default `lib/firebase_options.dart` = odc-chat (dev). `lib/services/multi_firebase_service.dart` compiles in 5 of them as runtime-switchable "knownProjects" (balkanz_nasr, balkanz_gym, cai_madenty, balkanz_zayed, dev; default `odc-chat`), with web fallbacks.

### Deploy configs: `deploy_configs/*/.cpanel.yml` (5 tenants)
Only difference is the cPanel deploy path (web hosting per tenant):
- dev -> printer.code-solution.org
- balkanz_gym -> blkan.code-solution.org (temporarily disabled per DEPLOY.md)
- balkanz_nasr -> blkan-madentnasser.code-solution.org
- balkanz_zayed -> balknszayed.code-solution.org
- cai_madenty -> cai.code-solution.org
`DEPLOY.md`: auto-deploy daily 05:00 to all active clients from `main` via GitHub Actions (repo YasserIbrahem1997/cai_); per-client manual dispatch; `dev` branch deploys to printer.code-solution.org only.

### URL-mode flags (web builds, `lib/main.dart`)
- `?mode=rm-web` or host `reports.code-solution.org` -> RM reports web mode (lines 158-159).
- `?mode=demo` -> demo user (line 378-390).
- `?mode=kiosk` -> kiosk self-order screen.
- `SettingsMenuScreen(useDemoMode: ...)` flag threads demo mode into printer settings.

---

## 9. Tax / VAT, service charge, currency, rounding

- **No global tax engine setting**: VAT and service charge live in the receipt design (`receipt_design_model.dart`): `showVat` (default false) + `vatPercent` (default 14.0), `showServiceCharge` (default false) + `serviceChargePercent` (default 12.0), `taxInclusive` (default false, "Prices after VAT, hides VAT line"), `showDeliveryFee` + `deliveryFee` (default 0.0).
- Currency: hardcoded EGP / ج.م (`lib/core/constants/app_locale.dart:6-9`). No rounding configuration found (no `rounding` knobs in receipt builder).
- Tax reporting side: ETA settings (section 5) + RM "Tax Report" permission.

---

## 10. Receipt customization (Receipt Designer, `receipt_designer_screen.dart`, 2427 lines)

Edits `ReceiptDesignModel` (full field list + defaults in `lib/features/settings/data/models/receipt_design_model.dart`):
- Logo: pick/change/remove, stored base64 (`logoBase64`), `showLogo` (true).
- Header & Footer (English only): `headerText` (default 'POS Pro Restaurant'), `footerText` ('Thank you for Visiting'), show toggles.
- Font settings: fontFamily ('Cairo'), header/body/footer font sizes (20/14/12).
- Paper size: 80mm (default) / 58mm; alignment center/right/left; table style Simple/Bordered/Striped; divider style dash/star/equal(default)/line.
- Display options: showDate, showOrderNumber, showCustomer, showItemPrice, showQuantity, showTotal (all true); showBranchName+branchName, showCashierName+cashierName (false); showPaymentMethod (false); showReprint banner (false).
- Charges & fees: service charge, VAT, delivery fee, tax inclusive (section 9).
- **Payment Method Labels**: per payment-method-id custom printed label map (`paymentLabels`).
- Preview per receipt type (Receipt/Kitchen/Sub-Receipt/Delivery) + Test Print.
- Storage: prefs `receipt_design` + Firestore `receipt_designs/{odooConnectionId}` (`firebase_receipt_service.dart:12,36`).

---

## 11. Feature flags

- **No Firebase Remote Config** anywhere (grep confirmed).
- Firestore-based flags (settings/app_config): `maintenanceMode` + `maintenanceMessage` (blocks app), `minAppVersion`, `showPrices`, `allowDiscounts`, `allowOfflineMode`, `tableSelectionEnabled`, `hideSendToKitchenButton` (default hidden), `dailyStockEnabled` (stock/sales-ratio master switch), `kioskEnabled`, `customerDisplayEnabled`.
- Firestore settings/pos_behavior: table security flags (section 6).
- Per-user flags on `pos_users`: isBlocked, quickLoginEnabled, allowed* lists.
- Compile-time: only `kDebugMode` guards (odoo_api_service.dart:100,470; session_close_screen.dart:3622). Tenant selection is compile/deploy-time via which `firebase_options.dart` is used + `MultiFirebaseService.knownProjects`.

---

## 12. Admin dashboard (`admin_dashboard _test/lib`) settings that control the POS

Separate Flutter web app writing into the same per-tenant Firestore:
- `models/app_settings.dart`: the authoritative shape of `settings/app_config`: odooUrl, maintenanceMode (default false), maintenanceMessage, minAppVersion (default '1.0.0'), showPrices (true), allowDiscounts (true), allowOfflineMode (true). Read/write in `services/firestore_service.dart:113-132`; toggled in `screens/dashboard_screen.dart` (maintenance switch line 1346, showPrices line 1380, etc.).
- `screens/odoo_connections_screen.dart`: CRUD of `odoo_connections` docs (name, url, database, isActive single-active, subscription window) that the POS resolves at login.
- `screens/branches_screen.dart` + `widgets/add_branch_dialog.dart`: branches.
- `screens/managers_screen.dart` + `models/manager_branch_assignment.dart`: manager accounts and branch assignments (RM web flow).
- `screens/firebase_projects_screen.dart` + `widgets/add_firebase_project_dialog.dart` + own `multi_firebase_service.dart` + `models/firebase_project_model.dart` / `firebase_platform_config.dart`: registry of tenant Firebase projects the dashboard can switch between.
- `widgets/add_user_dialog.dart` / `models/pos_user.dart`: pos_users management from the dashboard side.
- `utils/dev_project_gate.dart`: gates dev-only Firestore project usage.

---

## 13. Complete storage location map (settings-related)

### Firestore (per tenant project)
| Path | Contents | Written by |
|---|---|---|
| `settings/app_config` | maintenance, showPrices, allowDiscounts, allowOfflineMode, odooUrl, minAppVersion, tableSelectionEnabled, hideSendToKitchenButton, dailyStockEnabled, cartStyle, productsLayout, productCardStyle, menuPosition, tableSectionsLayout, customerDisplayEnabled, kioskEnabled, morningShiftStart/End | POS + admin dashboard |
| `settings/pos_behavior` | table security flags | pos_behavior_settings_service |
| `settings/print_routing` | per-terminal primary/backup receipt printer | print_routing_service |
| `settings/odoo_sync` | defaultPartnerId/Name, consolidated invoice | odoo_sync_settings_service |
| `settings/mall_sales` | percentage | mall_sales_settings_service |
| `settings/email_report` | SMTP + recipients + enabled | email_report_settings_service |
| `settings/whatsapp_report` | WAAPI creds + recipients + enabled | whatsapp_report_settings_service |
| `settings/eta_integration` | ETA env, company info, integrations, taxOnly | eta_service |
| `settings/eta_access_codes` | ETA viewer email whitelist | eta_access_service |
| `settings/category_appearance` | category colors/shape/height/font/align | category_appearance_service |
| `app_config/pos_server` | backend URL + login email | server_config_service |
| `pos_users/{odooUserId}` | role, permissions, allowed*, branch, PIN/quick-login, totp_secret, isBlocked | permission/quick-login services, roles screen |
| `odoo_connections/{id}` | Odoo url/db/isActive/subscription | admin dashboard |
| `printer_settings/global` (+ per-user) | cloud printer config | firebase_printer_service |
| `receipt_designs/{connectionId}` | receipt design | firebase_receipt_service |
| `receipt_templates/{connectionId}` | template ids + font profiles per receipt type | firebase_receipt_service |
| `ui_settings/{connectionId}` | grid_size | firebase_ui_settings_service |
| `discounts/{connectionId}` | discount types + allow amount | firebase_discount_types_service |
| `modifier_option_overrides/{connectionId}` | skip/hide rules | modifier_option_overrides_service |
| `quick_comments` | quick comment docs | firebase_quick_comments_service |
| `product_groups` | major groups (sortOrder, names, color) | product_group_service |
| `custom_pos_categories` | custom category defs | custom_category_service |
| `pricelists`, `branches` | pricelists + branch assignment | pricelist_service |
| `payment_methods/{id}` | flash include/exclude flag | mall_sales screen |
| `agent_heartbeat/{nodeId}` | POSPrint agent discovery | POSPrint exe |
| `print_jobs` | print job queue | app + POSPrint |
| `open_orders` | open orders admin | open_orders_screen |

### SharedPreferences (device-local; keys with defaults)
`is_dark_mode` (true), `app_locale` ('ar'), `cart_style` ('classic'), `products_layout` ('top'), `product_card_style` ('grid'), `menu_position` ('left'), `table_sections_layout` ('top'), `customer_display_enabled` (true), `kiosk_enabled` (false), `tables_count` (10), `allow_amount_discount` (false), `discount_types`, `pos_grid_size`, `printer_settings`, `printer_settings_products`, `printers`, `default_receipt_printer_id`/`default_sub_receipt_printer_id`/`default_delivery_printer_id`, `receipt_design`, `receipt_template_main|sub|delivery` ('classic'), `receipt_font_sizes_main|sub|delivery` ('default' profile), `legacy_agent_enabled` (false), `print_agent_url` ('http://127.0.0.1:9199'), `pos_terminal_name`/`pos_terminal_id`, `table_color_available|occupied|suspended|reserved`, `firebase_permissions` (owner-stamped cache), `pos_api_base_url` ('http://localhost:8000/api'), `pos_server_base_url_cloud`, `pos_server_login_email_cloud`, `ai_agent_base_url` ('http://164.68.100.86:9200'), `ai_agent_model`, `ai_gemini_api_key`, `email_report_*`, `wa_report_*`, `eta_client_id/secret/serial_number`, `eta_use_sandbox` (false), `odoo_sync_partner_id/name`, `odoo_sync_consolidated` (false), `mall_sales_percentage` (0.0), `category_*` appearance keys, `pos_require_password_to_open_table` (true) etc., `frozen_session_id`/`frozen_business_date_key`/`frozen_shift`, `active_cashier_shift`, `app_mode` (`app_mode_service.dart:29`), `pos_machine_id`, `firebase_selected_project_id` (legacy).

### On-disk agent configs (Windows tills)
- `pos_print_mesh.json` next to POSPrint.exe (section 3e).
- `print_agent_config.default.json` for legacy Node agent (section 3f).


---

# DETAILED FINDINGS: DishFlow POS — Functional Features + Backend Inventory

# DishFlow POS — Functional Features + Backend Inventory
Repo: `/home/username/workspace/Dishflow-pos` (Flutter + Firebase restaurant POS, branch `Test`). Odoo 18 is the ERP backend (companion repo CairoCaizer, module `flutter_api`, ~37 REST endpoints). Firestore is the real-time + offline sync layer; each branch = its own Firebase project (13 projects deployed, per `docs/STATE.md:24,39`).

## 0. Architecture overview
- Flutter app (lib/) runs Web (primary), Windows, iOS/Android, landscape tablet. Package `com.pos.pos_system`, title "POS Pro" (`README.md:96-101`).
- Data flow: Flutter → Odoo 18 via JSON-RPC/Bearer token (`lib/services/odoo_api_service.dart`, 3565 lines); Firestore for sales, sessions, print jobs, settings, permissions; local SharedPreferences for offline order storage.
- Two print paths (HTTP localhost:9199 direct vs Firestore `print_jobs` polling for HTTPS mixed-content) — `README.md:29-64`.
- Multi-tenant: `lib/services/multi_firebase_service.dart`, `firebase_config_service.dart`, `firebase_project_service.dart`, per-branch configs in `lib/firebase_configs/*/firebase_options.dart` (`docs/STATE.md:39`).
- Modes/shells: POS mode, RM (restaurant manager) mode, Transaction mode — `lib/features/auth/presentation/pos_mode_shell.dart` (2626 lines), `rm_mode_shell.dart`, `transaction_mode_shell.dart`, `mode_selection_screen.dart`. RM web login + branch selection: `rm_web_login_screen.dart`, `rm_web_branch_selection_screen.dart`. Separate manager mobile app in `rm_mobile_app/` ("DishFlow Reports (Mobile) — Firestore-only, no Odoo", `rm_mobile_app/README.md:1-3`).
- Shared-memory doc for agents: `docs/STATE.md` (architecture facts: sessions, driver dispatch, branch-name resolution, receipt printing).

## 1. Orders lifecycle
**Main POS screen:** `lib/features/pos/presentation/pos_screen.dart` (25,812 lines — the monolith).

- **Order types** (`pos_screen.dart:1032`, `access_control_defs.dart` keys): `Dine-in`, `Takeaway`, `Delivery from company`, `Store delivery`, `Car delivery`. Per-user allowed order types (`_allowedOrderTypes`, `pos_screen.dart:1556,6804`).
- **Offline order model:** `lib/services/offline_order_service.dart:25-156` — `OfflineOrder` with orderLines, payments[] (multi-payment `{payment_method_id, amount}`), tableNumber/tableId, shippingZoneId/Name, deliveryFee, deliveryDurationMinutes (SLA), orderType, discountType('percentage'|'fixed')/discountValue/discountAmount/discountReason, driverId/Name/Phone, deliveryCustomerName/Phone/Address, deliveryCompanyOrderNo, shift('morning'|'evening'), businessDateKey, sessionId, sessionDate, firebaseId, suspendedAt, cashierShiftId/cashierId/cashierName, isSynced/syncError/serverOrderId/serverOrderName.
- **Offline storage:** SharedPreferences per-user buckets (`offline_orders` key, `offline_order_service.dart:355-490`), deletion tombstones (`deleted_order_ids`, `deleted_suspended_order_ids`), rescue sync across buckets (`rescueSyncAllBuckets:874`), transfer suspended orders between cashiers (`transferSuspendedOrders:1208`, UI `lib/features/auth/presentation/transfer_orders_dialog.dart`).
- **Order numbering:** local-first global counter, never resets daily; `lib/services/open_order_service.dart:20-45` — format `DDMM-SEQ-TAG` (3-digit per-tab session tag), backed by Firestore `counters/order_global_seq`; recovery after cache clear via `getMaxPendingOrderNumber` (`firebase_sales_service.dart:203`) and `ensureCounterAheadOf` (`offline_order_service.dart:568`).
- **Hold/park (suspend):** suspended orders live locally + Firebase `suspended_orders` (full OfflineOrder JSON in `data` field) — `lib/services/firebase_suspended_order_service.dart` (302 lines); gated by permission `pos_suspend` (`pos_screen.dart:1154`). Resume-vs-new prompt for delivery (`docs/STATE.md:54`). Kitchen hold mode blocks auto-send of unsent items (`pos_screen.dart:1117`).
- **Edit after send:** `updateOrderContent/updateOrderFull` (`offline_order_service.dart:1029,1257`); `updateSaleContentInFirebase` (`firebase_sales_service.dart:596`); kitchen line deletions recorded (`recordKitchenLineDeletion:700`, `getDeletedKitchenLines:746`, Firestore `deleted_kitchen_lines`) and pushed to Odoo `pos_deleted_lines` module via `sendDeletedLines` (`odoo_api_service.dart:1046`, endpoint `/api/pos/deleted-lines`). Kitchen update slips printed on modification (`pos_screen.dart:13639` → `printKitchenUpdateSlip`).
- **Void/cancel:** `past_orders_screen.dart:1573 _performCancelOrder` → `cancelSaleInFirebaseByDocId` (`firebase_sales_service.dart:815`) with cancelledBy + reason and manager approval dialog (`_showAdminApprovalForAction:1782`); status becomes `cancelled` (no refund/credit-note concept — cancel only). Cancelled orders saved via `saveCancelledOrderToFirebase:1368`. Deletion/void tickets printed to kitchen (`receipt_print_service.dart:1083 printDeletionClassicSlip`, `1187 printDeletionWithRouting`).
- **Reprint:** past orders reprint requires manager approval (`past_orders_screen.dart:2265-2632 _PastReprintButton`, `_showAdminApprovalForReprint`); uses real `serverOrderName` so reprinted number matches (`docs/STATE.md:95`).
- **Modify past order / edit in cart:** `_performModifyOrder:1671`, `_performEditOrderInCart:1750`, edit order date dialog `:2037` (all approval-gated).
- **Sales storage (completed):** Firestore `sales` — full field map at `firebase_sales_service.dart:121-191`: odooConnectionId/Name, odooOrderId/Name, userId/userName, amount, itemsCount, paymentMethod, timestamp, syncedToOdoo, branchId/branchName, orderType, status('sale'|'cancelled'), partner_name, driver_id/name/phone, customer_name/phone, delivery_address, delivery_company_order_no, tableNumber, payments[], amountUntaxed, amountTax, shift, businessDateKey, sessionId, sessionDate, items[] (productId, productName, quantity, unitPrice, totalPrice, per-item discount fields, pos_category_name, modifiers[names]). Pending (offline, unsynced) sales via `savePendingSaleToFirebase:229` → `updatePendingSaleToSynced:429` once Odoo confirms.
- **Sessions:** deterministic emergent sessions — `session_YYYY-MM-DD_<shift>_<epoch>` (`lib/services/active_session_service.dart:90 composeSessionId`; open logic Cases A/B/C `:358-400`); no standalone sessions collection, uses `sales.sessionId` + `cashier_shifts` (`docs/STATE.md:40`). Business day via `lib/core/utils/business_date_utils.dart` (`computeBusinessDateKey`, cutoff hour 6). Firestore `active_sessions`.
- **Cashier shifts:** `lib/services/cashier_shift_service.dart` — Firestore `cashier_shifts`, per-device (`getDeviceId:187`), openShift/openShiftForCashier/flashAndLock (mid-shift flash lock), remote shift listener `:389`. Cashier login/PIN: `lib/features/auth/presentation/cashier_login_dialog.dart`, `cashier_selection_dialog.dart`, `cashier_reentry_pin_dialog.dart`.
- **Day/shift close:** two screens — `lib/features/orders/presentation/end_of_day_closing_screen.dart` (1227 lines, syncs pending Firebase→Odoo then report) and the full `lib/features/reports/presentation/session_close_screen.dart` (7219 lines): per-session totals, payment breakdown, sync-now, unsynced-old-sessions detection (`:3185`), previous synced sessions, permanent session delete (approval-gated `:1061`), email PDF/HTML/WhatsApp export buttons (`:2842-2866`), consolidated vs separate Odoo invoices (`lib/services/odoo_sync_settings_service.dart:6-8` — default partner + consolidated toggle), session report PDF attach to Odoo order (`attachSessionReport`, `odoo_api_service.dart` via `/api/sale/order/{id}/attach-session-report`).
- **Close guard:** `lib/features/reports/domain/session_close_guard.dart` — blockers = occupied tables, open orders, undelivered deliveries; fail-closed on error (`:56-60`).
- **Session tools:** `session_orders_dialog.dart` (2232), `session_sync_screen.dart`, `synced_sessions_screen.dart`, `merge_sessions_screen.dart`, `session_override_screen.dart`, `open_orders_screen.dart`, `order_sync_diagnostics_screen.dart` (settings).
- **Auto sync:** `lib/services/auto_sync_service.dart` — periodic Timer pushes pending offline orders + suspended orders to Firebase, reconciles with Firebase (`reconcileWithFirebase:344`). `InstantOrderService` (`instant_order_service.dart`) = fire-and-forget fast save (~1ms return, background persist).
- **Kitchen send pipeline:** `lib/services/kitchen_send_queue.dart` — serialized queue of {persistFn, printFn} tasks with retryPrint/dismiss; partial-error dialog `lib/features/pos/presentation/dialogs/kitchen_partial_error_dialog.dart`, preview `kitchen_preview_dialog.dart`.
- **Tables:** `lib/services/firebase_table_service.dart` (Firestore `tables`, `table_settings`) — occupy/suspend/resume/release/reserve, unsent-items flag, printed-receipt flag, reassign to cashier (`:674`), sections/spacers/row-breaks; UIs `tables_management_screen.dart` (3282), `table_reservation_screen.dart` (4888), `table_access_dialog.dart` (guarded table access), guest count dialog, `table_security_settings_screen.dart`. Multi-cart tabs, move items between tables/seats, transfer table (permission keys `pos_multicart`, `pos_move_items`, `pos_toolbar_transfer_table`).

## 2. Menu / catalogue
- **Source of truth = Odoo** via `flutter_api`: products `/api/pos/products`, categories `/api/pos/categories`, display categories CRUD `/api/pos/display-categories[/create|/update|/delete]`, product CRUD `/api/product/get|update|delete|update-pos-categories` (`lib/core/constants/api_constants.dart:16-46`; methods `odoo_api_service.dart:1076,1168,3281-3530`).
- **Models:** `lib/features/pos/data/models/pos_product_model.dart` (203), `pos_category_model.dart`, `product_attribute_model.dart` (variants/attributes), `product_modifier_model.dart` (676 — `ProductModifierModel` with minSelection/maxSelection/display_type radio-vs-multi `:106-107`, `ModifierOptionModel` with priceExtra + `sendToKitchen` flag `:167`, linked modifiers, `ProductWithModifiersModel`, `PriceCalculationModel`, `StockItemModel`).
- **Modifier flow:** `/api/pos/product/modifiers`, `/api/pos/calculate-with-modifiers` (server-side price calc), `/api/pos/validate-combo-selection` (combo validation) (`api_constants.dart:31-34`); selection UIs `product_modifier_screen.dart` (2029), `unit_modifiers_selector_screen.dart`; per-branch option overrides `lib/services/modifier_option_overrides_service.dart` (Firestore `modifier_option_overrides`); skip rules `settings/presentation/modifier_skip_rules_screen.dart`.
- **General additions** (Firebase-only modifiers, e.g. "no tomato"): `lib/features/pos/data/models/general_addition_model.dart` (Firestore `additions`, applies to all products when `product_template_ids` empty), admin UI `lib/features/products/presentation/general_additions_screen.dart` (951).
- **Products admin:** `products_screen.dart` (1088), `product_edit_screen.dart` (1328) — edit via Odoo `/api/product/update`, POS-category assignment, delete. Images via `lib/services/menu_media_service.dart` + `menu_media_screen.dart`.
- **Categories:** Odoo pos.category (display categories) + Firebase custom groupings: `lib/services/custom_category_service.dart` (Firestore `custom_pos_categories` — name + productIds + sequence, restricts POS product pool), UI `lib/features/categories/presentation/custom_categories_screen.dart` (1620); category colors `settings/presentation/category_colors_screen.dart`, appearance `lib/services/category_appearance_service.dart`; product groups `lib/services/product_group_service.dart` (Firestore `product_groups`) + `product_groups_settings_screen.dart`; product ordering `product_sequence_service.dart`.
- **Availability/stock toggles:** `lib/services/pos_stock_service.dart` — per-branch `pos_stock` Firestore collection (branch doc → product qty); in-POS stock edit sheet (`pos_screen.dart:2871 _showStockEditSheet`); stock deducted on completed sale (`pos_screen.dart:2852 _deductStockForCompletedSale`).
- **Pricing / pricelists:** Firebase pricelists `lib/services/pricelist_service.dart` (Firestore `pricelists`, rules, duplicate, assign/unassign to `branches`, default) + UI `settings/presentation/pricelist_management_screen.dart` (2402). Company-specific product prices for delivery companies (`shipping_companies/{id}/product_prices`, loaded in `pos_screen.dart:2745`). FastAPI backend has a parallel pricelist engine (see §11).
- **Customer QR menu (self-service):** `lib/features/menu/` — catalog published from POS local cache to Firestore `menu_catalog` (`menu_catalog_sync.dart` builds catalog with same POS filters; `firebase_menu_service.dart:251 syncMenuFromLocal`); customer views `menu_main_screen.dart`, `customer_menu_catalog_view.dart` (980), splash images (`menu_splash_screen.dart` + settings), QR print `menu_qr_print_screen.dart`; customer submits order → `menu_orders` collection with daily counter `menu_counters/{YYYY-MM-DD}` (`firebase_menu_service.dart:76-155`); order status tracking `order_status_screen.dart`; POS receives via `watchPendingOrders` (status in pending/received/paid), claims atomically with `tryClaimOrder` transaction (`:188`), links via `lib/services/menu_order_link_service.dart` → auto `markOrderCompleted` on payment; POS-side board `menu_orders_screen.dart` (403) maps items to cart (`menuOrderItemsToCartItems`).
- **Kiosk:** `lib/features/kiosk/presentation/kiosk_screen.dart` (869) — reuses `menu_catalog` + `menu_orders`, cart + modifiers, alarm sound on new orders (`kiosk_alerts_web.dart`, web-only).

## 3. Coupons + loyalty + customers
- **Coupons:** `lib/services/coupon_service.dart` — Firestore `coupons` {code (uppercased), type: 'percentage'|fixed, value, maxUses, usedCount, expiryDate, isActive, createdAt}; validate (exists/active/not-expired/uses-left `:101-138`), apply increments usedCount and clamps discount to order total (`:140-170`). UI `lib/features/coupons/presentation/coupons_screen.dart` (806).
- **Gift cards:** same service — Firestore `gift_cards` {code, balance, originalBalance, isActive, customerId}; `useGiftCard` deducts balance, auto-deactivates at 0 (`coupon_service.dart:271-299`).
- **Loyalty:** `lib/services/loyalty_service.dart` — config doc `loyalty_config/config` {pointsPerAmount, amountPerPoint, redemptionRate, isActive, tiers[{name, minPoints, discountPercent}] — default Silver/Gold/Platinum at 100/500/1000 pts with 2/5/10%}; points on `customers.loyaltyPoints` (FieldValue.increment), ledger `loyalty_transactions` {customerId, orderId, type earn|redeem, points, redemptionValue}; earn = floor(amount/amountPerPoint)*pointsPerAmount (`:102-105`); redeem checks balance (`:159`). UI `lib/features/loyalty/presentation/loyalty_settings_screen.dart` (685).
- **Discounts (order/item level):** order discount percentage|fixed with reason (staff/employee/VIP) on OfflineOrder; fixed-amount mode behind settings toggle (`docs/STATE.md:65`); per-item discount fields persisted in sales items (`firebase_sales_service.dart:158-186`); discount types managed in `lib/services/firebase_discount_types_service.dart` + `firebase_discount_service.dart` (Firestore `discounts`) and `settings/presentation/discount_types_settings_screen.dart`; permission `apply_discount` + manager auth.
- **Customers:** Odoo partners via `/api/customers` (`odoo_api_service.dart:1551 getCustomers`), UI `lib/features/customers/presentation/customers_screen.dart` (750, search against Odoo). Separate lightweight **delivery customers** in Firestore `delivery_customers` (`lib/services/delivery_customers_service.dart` — saveCustomer, search, getRecent) used for Store-delivery phone/name/address capture. Firestore `customers` used for loyalty points.

## 4. Delivery + shipping
- **Zones:** `lib/features/shipping/data/models/shipping_zone_model.dart` — {name, deliveryPrice, deliveryDurationMinutes (SLA, 0 = none)}; service `shipping/data/services/shipping_zone_service.dart` (Firestore `shipping_zones`); UI `shipping_zones_screen.dart` (888). Zone fee lands on order as `deliveryFee`.
- **Delivery companies:** `shipping_company_model.dart` — {name, phone, notes, fixedCustomerId/Name (auto-selected Odoo partner)}; per-company drivers subcollection `shipping_companies/{id}/drivers` and per-company product price overrides `product_prices` (`firestore.rules:65-71`); UIs `shipping_companies_screen.dart` (1729), `shipping_drivers_screen.dart` (747). Company order-no captured (`deliveryCompanyOrderNo`).
- **Store drivers:** top-level `drivers` collection + `drivers/{id}/orders` (write-only, no driver app — `docs/STATE.md:42,84`); source of truth for assignment = `sales.driver_id`; drivers admin `drivers_screen.dart` (938) with Excel import/export + driver `code` field (`docs/STATE.md:56`).
- **Delivery board:** `lib/features/shipping/presentation/delivery_orders_screen.dart` (2252) — one widget parameterized `deliveryTypeFilter` 'store'|'company', tabs unassigned/assigned/all, reads `sales`, driver dropdown → `_assignDriver`; delivery statuses `received→sent→on_the_way→delivered` (`lib/core/utils/delivery_status_utils.dart`); refresh bus `lib/services/delivery_orders_refresh_bus.dart`. Second, simpler local-orders board in `lib/features/delivery/presentation/delivery_orders_screen.dart` (870) + `delivery_order_detail_screen.dart` (926) reading `OfflineOrderService` with PDF printing.
- **SLA monitoring:** `lib/core/utils/delivery_sla_utils.dart` + `lib/services/delivery_sla_monitor.dart` — app-wide timer computing late deliveries from zone `deliveryDurationMinutes`, alarm + navigator overlay.
- **E-commerce integration (IMPLEMENTED):** plan `docs/ECOMMERCE_DELIVERY_INTEGRATION.md`; mobile app writes `ecommerce_orders` {orderNumber (daily counter `ecommerce_counters/{date}`), source:'ecommerce', status pending→received→completed/cancelled, subtotal, deliveryFee, discount, totalAmount, currency, items[] (product_id, product_template_id, name/name_ar, quantity, price_unit/unit_price/total_price, notes, modifiers), customer_name/phone, order_type delivery|pickup, delivery_address/area/lat/lng, payment_method, payment_status, branchId/branchName, restaurantId, dishflowOrderId/Number, createdAt}. POS side: `lib/services/firebase_ecommerce_order_service.dart` (watchStoreOrders whereIn pending/received `:28`, tryClaimOrder transaction `:38`, markCompleted soft-complete `:78` — backend listener maps completed→DELIVERED, never hard-delete, markCancelled `:99`); cart mapping `ecommerce_order_cart_mapper.dart`; link-and-complete-on-payment `ecommerce_order_link_service.dart`; merged into shipping board (`shipping/presentation/delivery_orders_screen.dart:61-131`) with claim button + kiosk alarm sound; access key `delivery_orders_store` (`access_control_defs.dart:36`).

## 5. Warehouse / inventory
- **Warehouse orders (branch requisitions to central warehouse, Odoo-backed):** endpoints `/api/warehouse/products-unavailable`, `/api/warehouse/warehouses`, `/api/warehouses/all`, `/api/warehouse/order/create`, `/api/warehouse/orders`, `/api/warehouse/order/{id}/receive` (`api_constants.dart:60-66`; methods `odoo_api_service.dart:2648-2761`). Model `lib/features/warehouse/data/models/warehouse_order_model.dart` — states draft/confirmed/done, lines {product, qty, uom, source_warehouse}; `UnavailableProductModel`. UI `warehouse_order_screen.dart` (1129). Firestore cache `warehouse_cache/{connectionId}` (`lib/services/firebase_warehouse_service.dart`).
- **POS on-hand stock:** `pos_stock_service.dart` (Firestore `pos_stock` per branch) — manual counts, deduction on sale, low-stock surfaced in POS grid.
- **Daily stock count/reconcile:** `lib/features/reports/data/daily_stock_controller.dart` + `daily_stock_reconcile.dart` (Firestore collection with opening/closing sides, save/loadRange), UIs `daily_stock_screen.dart`, `daily_stock_reconcile_dialog.dart`; edit stock closing from session close (`session_close_screen.dart:2810`); toggle `dailyStockEnabled` in `settings/app_config` (`firebase_permission_service.dart:296`).
- **No recipes/BOM** found — inventory is product-level only.

## 6. Expenses & attendance
- **Expenses:** Odoo-backed — `/api/expense/create`, `/api/expenses` (`odoo_api_service.dart:2563,2606`); model `lib/features/expenses/data/models/expense_model.dart` {id, name, amount, description, date, state, journalName, category}; UI `expenses_screen.dart` (756); Firestore cache `expenses_cache`; report `/api/expenses/report` (`odoo_api_service.dart:3068`).
- **Attendance (fingerprint):** hardware agent `zk_fingerprint_agent.py` — Flask on :9201 for ZKTeco ZK8500R via pyzkfp (Windows-only, simulation mode fallback); endpoints `/ping /connect /disconnect /status /capture /register /identify /merge /clear_pending /load_templates /templates` + delete; templates persisted to `templates.json`; launcher `start_zk_agent.bat`, installer `zk_agent_setup/`. Flutter client `lib/services/fingerprint_service.dart` (Dio to 127.0.0.1:9201, cached readiness/warmUp).
- **Attendance data:** `lib/services/firebase_attendance_service.dart` — Firestore `fingerprint_templates` (per userId) + `attendance` {userId, dateKey, timestamps...}; `watchTodayAttendance` stream. Screens: `attendance_registration_screen.dart` (798 — enroll fingerprints), `attendance_screen.dart` (683 — log view), `cashier_attendance_screen.dart` (1381 — admin grid of cashiers green/red by open cashier_shift in current session; check-in opens shift via password `CashierShiftService.openShiftForCashier`; ties attendance to shifts/flash reports).
- Fingerprint also usable for quick login (`quick_login_service.dart:293 findUserByMatchedFingerprintId`) alongside PIN quick login (`findUserByPin:278`, setup dialog `auth/presentation/widgets/quick_login_setup_dialog.dart`).

## 7. Kitchen (KDS + tickets)
- **KDS:** `lib/features/kitchen/presentation/kitchen_display_screen.dart` (600) — live query on `sales` where timestamp >= start of day (`:46`); bump = sets `kitchenStatus` field on the sale doc without touching order status (`:53-63`); board hides `status=='cancelled'` and `kitchenStatus=='ready'` (`:138-142`); live clock, per-order cards with elapsed-time coloring. Recall = ready orders drop off view (no dedicated recall queue). Permission `view_kds` / screen key `kds`.
- **Ticket routing / station filtering:** kitchen printers typed `kitchen` in `printer_model.dart`; per-category kitchen routing via Firestore `kitchen_product_categories` (referenced in services grep) and routing helper `lib/features/pos/presentation/printer_routing_helper.dart`; per-printer `skipModifiers` / `groupModifiers` / `fallbackPrinterId` (`printer_model.dart:9-22`); modifier option `sendToKitchen` flag controls whether an option prints on kitchen tickets.
- **Send-to-kitchen flow:** `pos_screen.dart:12042-12281` — persist + print handed to `KitchenSendQueue`; per-printer slip printing `receipt_print_service.dart:679 printKitchenSlip`, updates `:982 printKitchenUpdateSlip`; kitchen receipt preview screen `pos/presentation/kitchen_receipt_screen.dart` (1805); hide-send-to-kitchen app config toggle (`firebase_permission_service.dart:286`).
- Deleted kitchen lines audit: Firestore `deleted_kitchen_lines` + Odoo `pos_deleted_lines` + deletion slips printed to kitchen.

## 8. Reports (lib/features/reports) — complete catalog
Entry: `reports_menu_screen.dart` (5140; card list `:150-380`) and RM `reports_dashboard_screen.dart` (4421). Access keys per report in `access_control_defs.dart` (`sales.*`, `analytics.*`, `labor.*`).
1. **Reports Dashboard** — `reports_dashboard_screen.dart` (KPIs, charts, right panel `widgets/rm_dashboard_right_panel.dart`).
2. **Items Sales Report** — `items_sales_report_screen.dart` (1566) + XLSX export `lib/core/utils/items_sales_report_xlsx.dart` + allocation util `utils/items_sales_allocation.dart`; session items PDF `widgets/session_items_sales_pdf.dart`.
3. **Detailed Orders Report** — `detail_orders_report_screen.dart` (976).
4. **Discounts Report** — `discounts_report_screen.dart` (989); **Detailed Discounts** — `detailed_discounts_report_screen.dart` (844).
5. **Audit Trail** — `audit_trail_report_screen.dart` (655; from `audit_log_service.dart` Firestore `activity_logs` + `order_actions_log`).
6. **Revenue Centers** — `revenue_center_report_screen.dart` (814; by order type/center).
7. **Tax Report** — `tax_report_screen.dart` (777) + calc `utils/tax_report_calc.dart` + XLSX `core/utils/tax_report_xlsx.dart`.
8. **Expenses Report** — `expense_report_screen.dart` (Odoo expense data).
9. **Cost vs Sales** — `cost_vs_sales_report_screen.dart` (792; standard_price vs revenue).
10. **Advanced Analytics suite** — `advanced_analytics_screen.dart` (1108) + `analytics_menu_screen.dart`: Top Products (`analytics/top_products_report_screen.dart`), Category Performance, Sales by Time, Sales by Day, Cashier Performance, Period Comparison, Modifier Analysis (587; uses `utils/modifier_aggregation.dart`), Payment Analysis.
11. **Delivery reports** — Detailed Delivery (`delivery_report_screen.dart` 912), Delivery by Drivers (`delivery_report_drivers_screen.dart` 591), Driver Delivery (`driver_delivery_report_screen.dart` 629).
12. **Cancelled/Modified Orders** — `cancelled_modified_orders_report_screen.dart` (1090).
13. **ETA invoices** — history `eta_invoice_history_screen.dart` (1344) + submission wizard `eta_invoice_wizard.dart` (1420).
14. **Current Session Payments** — `current_session_payments_report_screen.dart` (828).
15. **Session Close / End of Day** — `session_close_screen.dart` (7219) + `session_summary_report.dart` (2644).
16. **Flash Report** (mid-shift, manager-authorized) — `flash_report_screen.dart` (1970), thermal printer output `services/flash_report_printer.dart` (749), PDFs: `widgets/flash_report_pdf.dart`, `flash_control_thermal_pdf.dart`, `flash_delivery_thermal_pdf.dart`, `flash_mall_sales_thermal_pdf.dart` (mall commission % from `mall_sales_settings_service.dart` — settings/mall_sales), view `flash_report_view.dart`; past-flash reprint (`reports_menu_screen.dart:554`).
17. **Menu Engineering** — `menu_engineering_screen.dart` (1367; stars/plowhorses quadrant analysis).
18. **Daily Stock** — `daily_stock_screen.dart` + reconcile dialog.
Report plumbing: period picker `widgets/period_selection_dialog.dart` (753), period fetch `utils/sales_period_fetch.dart`, sales classifier `utils/sales_classifier.dart`, payment-name resolution chain `utils/odoo_payment_name_resolver.dart` + `payment_name_resolver_loader.dart` (4 sources: Odoo journals → Firebase payment_methods → local journal_names cache → session_adjustments; precedence documented in `docs/ODOO_TOKEN_AND_PAYMENT_NAMES.md:74-160`), branch name always via `utils/branch_name_resolver.dart` (authoritative `branches/{branchId}.name` — never `perm.branchName`, `docs/STATE.md:43`). Exports: CSV/XLSX (`core/utils/csv_export*.dart`, `xlsx_export*.dart`), PDF (pdf/printing packages), Email PDF (`email_report_sender.dart` 522 + `email_report_settings_service.dart` + settings screen), WhatsApp via WAAPI with tmpfiles.org hosting (`whatsapp_report_sender.dart:20-24` + settings), demo mode flags on report screens (`useDemoMode`).

## 9. Printing architecture end-to-end
**Flutter side:**
- Dispatcher `lib/services/receipt_print_service.dart` (2858): main receipt `printReceipt:1916` (order type banners, delivery-printer fallback), `printDeliveryReceipt`, kitchen `printKitchenSlip:679` / update `:982`, sub-receipt/order slip `printSubReceipt:1371`, deletion slips `:1083,:1187`, dynamic template `printDynamicTemplate:660`, PDF fallback when no agent (`:1910` opens browser print dialog), per-printer skip/group modifiers + fallback resolution (`:76-133`), design + logo from Firestore `receipt_designs` (`firebase_receipt_service.dart`), font-size profiles in `printer_settings/global` (`firebase_printer_service.dart:222-255`).
- Receipt templates: `receipt_template_builder.dart` (650), designer UI `settings/presentation/receipt_designer_screen.dart` (2427), models `receipt_design_model.dart`, `receipt_template.dart`, `receipt_font_sizes.dart`.
- Arabic rendering: `arabic_escpos_renderer.dart` (2228) — pre-rendered raster bitmaps so Arabic works on any printer/web.
- Transports: direct TCP ESC/POS (desktop) `escpos_tcp_service.dart`; web JS bridge `print_agent_js_bridge_web.dart` (`thermalPrintViaAgent()` direct HTTP, no WebSocket — `README.md:462`); Firestore queue `print_job_service.dart` (enqueueRaw/Kitchen/Receipt/SubReceipt → `print_jobs`); agent discovery `agent_discovery_service.dart` (LAN /ping probing); printer init `printer_initialization_service.dart`.
- Terminal routing: `print_routing_service.dart` — per-terminal primary/backup receipt printers in `settings/print_routing`; terminals auto-register in `pos_terminals` ("POS 1..N" auto-naming `:22-66`).
- Printer admin: `printers_management_screen.dart` (2270), `printers_settings_screen.dart` (2602), diagnostics `print_diagnostics_screen.dart` (1887). Printer configs in Firestore `printers` / `printer_settings` (global/per-user with admin fallback `firebase_printer_service.dart:135`).
- **print_agent_setup/** (deployed Node agent, v2.9.1): `print_agent.js` (4574) — HTTP :9199 (LAN-wide) endpoints `/ping /status /scan /printers/health /test-printer /print/test /print/raw /print/deletion /print/kitchen /print/receipt /print/sub-receipt /print/dynamic` (`:3531-3978`); ESC/POS builders with template styles classic/classic_modern/cai/compact per receipt/kitchen/sub-receipt (`:726-1864`); per-printer-IP mutex queue (`:60-90`); ALSO polls Firestore `print_jobs` every 10s with agent claim id `hostname-pid`, job expiry 10 min (anti flood-print after outage), stale-claim recovery 2 min (`:32-55`); heartbeat 5s; opt-in modules `lib/config-loader, queue, health-monitor, fallback-router`; Windows installer `installer.iss`, build bats, release notes 2.6.x-2.7.x.
- **pos_print_mesh/** (Smart Print Mesh v2.0.0, Dart, feature branch): single compiled `POSPrint.exe`; subnet scanner for :9100 printers; HTTP :9199 (`/ping /printers /status /print/raw|kitchen|receipt|sub-receipt`); Firestore polling; role-based routing (receipt|kitchen|sub_receipt|delivery) with healthy-fallback same-role; retry (5×, 15s) via `retry_after`; multi-node mesh: claim (`status=processing, claimed_by=nodeId`), stale reclaim 60s, heartbeat `agent_heartbeat/{nodeId}` with printer health; job lifecycle pending→processing→done/failed (`pos_print_mesh/README.md:102-371`); 85 unit tests + integration tests; built by GitHub Actions, served at `/POSPrint.exe` from the web build; source `lib/src/{config,mesh,firestore,http_server,escpos,scanner}.dart`.
- **Legacy print_agent/** (6 implementations: Node HTTP, Node Firebase, Python HTTP, Python Firebase, Dart, precompiled exe) documented `README.md:307-371`; zips at repo root.

## 10. Cloud Functions, FastAPI backend, Email
- **functions/index.js** (159 lines, region europe-west1):
  1. `sendEmail` (callable, public invoker) — Nodemailer SMTP (env-configured, default host mail.code-solution.org:465; fails closed without SMTP_PASS `:36-42`); supports to/cc/bcc, html/text, base64 attachments (`:74-81`). Used by `lib/services/email_service.dart` (sendEmail, sendSessionCloseReport + HTML builder) and `email_report_sender.dart` (PDF attachments). Docs `EMAIL_SERVICE_GUIDE.md`, `EMAIL_SERVICE_SUMMARY.md`, `EMAIL_QUICK_START.md`.
  2. `etaProxy` (HTTP onRequest) — server-side proxy restricted to `*.eta.gov.eg` to bypass CORS for Egyptian Tax Authority calls (`:108-158`), reached through Firebase Hosting rewrite `/api/etaproxy`; stub host page `hosting_eta_stub/index.html`.
- **pos_backend/** (FastAPI + SQLAlchemy async + Alembic; client `lib/services/pos_api_service.dart` base `http://localhost:8000/api`; "replaces direct Firestore/Odoo calls" — an alternative/experimental backend):
  - Auth: `POST /auth/login` (verifies against Odoo via `OdooSyncService.verify_credentials`, auto-creates local user, JWT), `GET /auth/me` (`app/api/routes.py:91-171`).
  - Products: `GET /products` (search/category/branch pricelist overrides, 30s full-catalog cache `:186-263`), `GET /products/{id}`; Categories `GET /categories`.
  - Branches CRUD + members add/remove (`:298-438`); Roles CRUD (system-role protected `:445-518`); Users list/update/assign-branch (`:525-596`).
  - Pricelists: CRUD, duplicate, rules replace, `bulk-adjust` % by category, `resolve/{product_id}` price resolution branch→default→base (`:603-893`).
  - Orders: list w/ filters, `POST /orders` idempotent by `client_uuid` (race-safe IntegrityError fallback `:933-969`), update, status update (open/completed/cancelled/refunded `:35`).
  - Audit logs list/create (+ `/audit` alias); Settings key/value map; Sync: `/sync/full`, `/sync/products`, `/sync/categories`, `/sync/orders` (push), `/sync/logs`, auto-sync toggle; `/health` (`:1019-1222`).
  - Odoo sync svc `app/services/odoo_sync.py` (sync_categories/products/users, push_orders, run_full_sync); models `app/models/models.py` (Branch, Role, User w/ TOTP + permissions JSON, Category, Product incl. taxes/pos_category_ids, Pricelist(+Rule), Order, AuditLog, Setting, SyncLog); `loadtest/`, `tests/`, `migrations/`.

## 11. Odoo touchpoints
- **Client:** `lib/services/odoo_api_service.dart` — Dio singleton, token + expiry stored in SharedPreferences (`api_token`, `token_expiry`); expiry checked only at startup (`docs/ODOO_TOKEN_AND_PAYMENT_NAMES.md:38-66` — no auto-refresh; only price-calc handles INVALID_TOKEN mid-session `odoo_api_service.dart:2487`); default URL `http://localhost:8069` (`api_constants.dart:5`, README says use 8072).
- **Endpoint inventory** (`api_constants.dart:8-71`): auth login/logout/verify-credentials/users-info/users-create; pos products/categories/deleted-lines/session-adjustment; products; customers; sale order create/list/details/attach-session-report; modifiers (products-with-modifiers, product/modifiers, calculate-with-modifiers, validate-combo-selection); product get/update/delete/update-pos-categories; display categories CRUD; payment methods + account/payment journals (`odoo_api_service.dart:1926-1943` incl. `call_kw` fallbacks + `/web/dataset/call_kw`); print receipt (server-side Epson); expense create/list; warehouse (6 endpoints); dashboard sales/top-products/recent-orders; reports `/api/sales/report`, `/api/customers/report`, `/api/expenses/report`.
- **Sale sync:** checkout → `createSaleOrder` (`odoo_api_service.dart:2084`) → mark Firebase sale `syncedToOdoo` (`updatePendingSaleToSynced`); session close can send one consolidated invoice on a default partner or per-order invoices (`odoo_sync_settings_service.dart`, `session_close_screen.dart:2329-2385`) and attach the session PDF to the Odoo order. Payment methods = Odoo `account.journal` ids (journal_id) with 4-source name resolution (see §8); `docs/ODOO_TOKEN_AND_PAYMENT_NAMES.md` documents expired-token behaviour, silent fallback and cache-overrides-live bug.
- **ETA (Egypt e-invoicing):** `lib/services/eta_service.dart` (1040) — multiple integrations per order type (clientId/secret/serial per integration, sandbox toggle, RIN/trade name/activity code) stored under Firestore `settings`; token fetch, submitDocuments/submitReceipt, recent documents; POS marks sales `markSaleAsEtaSubmitted` (`firebase_sales_service.dart:2800`); access management `eta_access_service.dart` + `settings/presentation/eta_settings_screen.dart` (1381), `eta_access_management_screen.dart`; goes через `etaProxy` cloud function on web.

## 12. Admin dashboard (`admin_dashboard _test/`)
Separate Flutter web app (port 8090, same Firebase project; known broken firebase_auth dep — `README.md:486-489`). A manager can:
- Login (`screens/login_screen.dart`, `services/auth_service.dart`, sessions `services/session_service.dart`).
- Overview dashboard (`screens/dashboard_screen.dart`, stats cards).
- Manage **branches** (`screens/branches_screen.dart`, `widgets/add_branch_dialog.dart`; model `branch_model.dart`).
- Manage **Odoo connections** (`screens/odoo_connections_screen.dart`; model `odoo_connection.dart`) — switch the active connection used by all POS devices (Firestore `odoo_connections`).
- Manage **Firebase projects** per branch (`screens/firebase_projects_screen.dart`, `add_firebase_project_dialog.dart`; models `firebase_project_model.dart`, `firebase_platform_config.dart`).
- Manage **managers** + branch assignments (`screens/managers_screen.dart`, `add_manager_dialog.dart`; models `manager_model.dart`, `manager_branch_assignment.dart`).
- Manage **POS users** (`widgets/add_user_dialog.dart`, `user_card.dart`; model `pos_user.dart`).
- View **sales dashboard** (`screens/sales_dashboard_screen.dart`; model `sale_record.dart`).
- App settings (`models/app_settings.dart`, `widgets/settings_card.dart`); emulator gate `utils/dev_project_gate.dart`.

## 13. Cross-cutting / misc features
- **Auth & access control:** Odoo login (email) + Firebase `pos_users` permission docs (`lib/services/firebase_permission_service.dart` — UserScope, allowed screens/permissions/order types, app_config toggles); role/permission catalog `lib/features/settings/presentation/access_control_defs.dart` (screens, view_*/action permissions, mode keys pos/delivery/admin/rm/transaction, order-type keys, POS toolbar-button-level keys, per-report keys); roles UI `roles_access_screen.dart` (2844), users `users_management_screen.dart` (982); manager approval dialog `manager_auth_dialog.dart` (1184); TOTP 2FA `totp_service.dart` + `totp_setup_screen.dart`; quick login by PIN/fingerprint; secure delete dialog `secure_delete_dialog.dart` (1150).
- **Audit/activity:** `audit_log_service.dart` (725, Firestore `activity_logs` + `order_actions_log`), `activity_logger_service.dart`, navigator observer `core/navigation/audit_navigator_observer.dart`; UIs `activity_logs_screen.dart` (1348), `audit_log_screen.dart` (840).
- **Customer-facing display:** `customer_display_service.dart` (cart mirrored via Firebase) + screens `customer_display_screen.dart`, `customer_display_standalone_screen.dart`, slider settings.
- **AI assistant:** `ai_chat_service.dart` (Dio to AI agent backend default `http://164.68.100.86:9200`, Gemini key option, sends Firestore business context), `ai_action_service.dart`, settings `ai_settings_screen.dart` (517).
- **Ops:** `backup_service.dart` (export/import local data), cache clear services, fullscreen service, Sentry (`sentry_helper.dart`), branch management UI `branch_management_screen.dart` (1870), server settings screens, session status watcher, business-hours/locale (`core/localization`, Arabic/English `tr()` everywhere), theming `core/theme`.
- **Quick comments:** `firebase_quick_comments_service.dart` (Firestore `quick_comments`) + settings screen — canned order notes.
- **Session adjustments:** `firebase_session_adjustment_service.dart` (Firestore `session_adjustments` — post-close payment corrections; feeds payment-name resolver + `/api/pos/session/adjustment` in Odoo).
- **Stats:** `firebase_stats_service.dart`, `local_stats_service.dart`, Firestore `dashboard_stats`.

## 14. Firestore data model (collection index)
From `firestore.rules:3-97` and service constants: `odoo_connections`, `pos_users`, `settings` (docs: app_config, print_routing, mall_sales, odoo_sync, ETA docs), `roles`, `shipping_zones`, `shipping_companies` (+subcols `drivers`, `product_prices`), `drivers` (+subcol `orders`, write-only), `print_jobs`, `agent_heartbeat`, `branches`, `sales`, `suspended_orders`, `expenses_cache`, `warehouse_cache`, `menu_catalog`, `menu_orders`, `menu_counters`, `ecommerce_orders`, `ecommerce_counters`, `coupons`, `gift_cards`, `customers`, `loyalty_config`, `loyalty_transactions`, `discounts`, `pricelists`, `custom_pos_categories`, `product_groups`, `additions`, `modifier_option_overrides`, `pos_stock`, `kitchen_product_categories`, `tables`, `table_settings`, `open_orders`, `counters` (order_global_seq), `active_sessions`, `cashier_shifts`, `session_adjustments`, `dashboard_stats`, `deleted_kitchen_lines`, `printer_settings`, `printers`, `pos_terminals`, `receipt_designs`, `quick_comments`, `activity_logs`, `order_actions_log`, `fingerprint_templates`, `attendance`, `delivery_customers`, `payment_methods`. Rules default-allow at the bottom (`firestore.rules:97` `match /{document=**}`); tighter proposals in `firestore.rules.proposed`, `firestore.rules.step1`. Composite indexes `firestore.indexes.json` fanned out to 13 branch projects via `deploy_firestore_indexes.sh`.

## 15. Offline behaviour summary (per domain)
- Orders: fully offline-capable — local SharedPreferences buckets, local-first order numbering with Firebase counter reconciliation, tombstones against resurrection, AutoSyncService periodic push to Firebase, then Firebase→Odoo sync at session close or on-demand; `syncedToOdoo`/`firebaseSynced` flags per order; rescue sync across user buckets.
- Catalogue: products/categories/modifiers cached locally (`local_storage_service.dart` 1338 + `large_kv_store*.dart`); menu catalog published snapshot to Firestore for QR/kiosk clients.
- Printing: desktop prints direct TCP offline; web needs local agent (HTTP) or Firestore queue (online); job expiry prevents post-outage flood printing (`print_agent_setup/print_agent.js:44-46`).
- Payment names/reports: silent fallback to local `journal_names` cache when Odoo token expired (risk: stale names / `غير محدد`, `docs/ODOO_TOKEN_AND_PAYMENT_NAMES.md:135-160`).
- Sessions/shifts: cached locally (`active_cashier_shift`, session in prefs) and restorable from Firebase (`active_session_service.dart:503 restoreFromFirebase`).

## 16. Known gaps / notable design facts (for synthesis)
- No true refund/credit-note flow; only cancel with reason + approval.
- `drivers/{id}/orders` write-only dead data (`docs/STATE.md:84`).
- No Odoo token auto-refresh; one INVALID_TOKEN handler (`odoo_api_service.dart:2487`).
- KDS bump is a field on `sales` (`kitchenStatus`), not a ticket queue; no per-station KDS filtering in KDS screen itself (station filtering happens at print-routing level).
- Firestore rules effectively open (default allow-all match).
- pos_backend (FastAPI) is a parallel/alternative backend not wired as primary; the shipped path is Odoo flutter_api + Firestore.
- Till owns numbering/data locally; server (Odoo) is a sync destination — same philosophy the newer offlinePOS repo formalizes.


---

# DETAILED FINDINGS: offlinePOS Architecture + Odoo Sync Inventory

# offlinePOS Architecture + Odoo Sync Inventory

Repo: `/home/username/workspace/offlinePOS` (branch `main`, 136 commits, last commit 2026-08-14). Flutter desktop-first app (android/, linux/, windows/ platform dirs; Codemagic Windows workflow in `/home/username/workspace/offlinePOS/codemagic.yaml`). Package name `offline_pos`.

Key deps (`/home/username/workspace/offlinePOS/pubspec.yaml`): `sqlite3 ^2.4.0`, `sqlcipher_flutter_libs ^0.7.0+eol`, `flutter_secure_storage ^11.0.0`, `cryptography ^2.9.0` (Argon2id + Ed25519), `http ^1.6.0`, `crypto` (sha256). No drift, no sqflite, no connectivity_plus: raw `sqlite3` FFI and a hand-rolled HTTP probe.

**README staleness confirmed**: `/home/username/workspace/offlinePOS/README.md` "Not built yet" section (~line 37) claims encrypted SQLite, Argon2id, the Odoo sender, ESC/POS printing and the UI don't exist. All five exist and are tested (evidence below). Trust code.

## 1. Docs: intended design + promised Odoo mapping

- `/home/username/workspace/offlinePOS/docs/ARCHITECTURE.md`
  - Core rule (line 24): "The till owns its data. The server is a destination, not a dependency." No screen blocks on network; no sale requires a round trip.
  - Identity (lines 30-38): client-generated UUID is the identity forever; server ids stored only as reference. This is the idempotency/replay foundation.
  - Sync (lines 42-51): append-only outbox, drained in order, retry, idempotent, nothing deleted until server ack.
  - **Stale paragraph** (lines 56-62): says "Encryption at rest is not implemented... the dependency is the plain sqlite3 build". Contradicted by code and by SECURITY.md's own checklist: SQLCipher is wired and proven (see section 2).
  - Auth design (lines 69-81): two layers, signed time-boxed device token (grace period > worst outage) + local Argon2id cashier PIN. Note: the device-token half is NOT implemented (section 6).
  - Updates (lines 91-96): never update with unsynced orders or mid-shift; sync API keeps N-1/N-2 compatibility; staged rollout.
- `/home/username/workspace/offlinePOS/docs/ODOO_SYNC.md` (the promised mapping, matches code)
  - **Not pos.order**. An offline sale books the full on-site chain via a custom Odoo module: `sale.order -> action_confirm -> delivery validated (stock.move) -> posted customer invoice (account.move) -> payment registered (account.payment)` (lines 5-24). Rationale: customer reports read sale.order/stock.move/account.move; a bare pos.order feeds none.
  - Entry point: `sale.order.create_from_offline_pos(payloads)` in the **`pos_offline_sync` Odoo module** (line 25). That module is NOT in this repo (no .py files here); per project memory it lives in the jouma repo on branch Staging_osam.
  - Backdating: records dated to ring time, valuation date via jouma's `stock_accounting_date_adjustment` (lines 20-24).
  - Cadence (lines 27-44): push at **shift close** as one batch, or manual "Sync now"; the 20s background loop is read-only (version_info probe + catalogue refresh) and never drains orders.
  - Auth method (lines 55-74): a single shared integration user (`offlinepos_sync` on staging), password is runtime config, not baked in. Required Odoo groups: POS User, Sales, Invoicing, Inventory/User, Stock Accounting Date Manager, plus an email on the user (message_post author).
  - Wire contract (lines 75-100): payload carries `uuid` (idempotency), `created_at`, `cashier_id`, `device_id`, lines with `product_id/quantity/unit_price`, modifier lines with their own `product_id`. Server replies one status dict per order: `created` / `duplicate` (both ack) / `rejected` (park). Each order booked in its own savepoint.
  - Queue kinds (lines 110-117): `order.push` (keyed on order uuid), `audit.push` (`audit-<id>`), `device.status` (keyed on device id, replaces).
- `/home/username/workspace/offlinePOS/docs/SECURITY.md`
  - Hard rules: binary is public, no secrets in app, Argon2id ~100ms, attempt limit mandatory, SQLCipher w/ keystore key, signed+pinned updates, licensing must never block a sale.
  - Go-live checklist (lines 77-91): **[x] SQLCipher done** ("proven: data not clear text, wrong key rejected"), [x] Argon2id + persisted escalating lockout, [x] signed updates Ed25519 + pinned transport + install-time digest recheck, [x] no credentials in repo. Open: [ ] backend rules deny-by-default/tenant-scoped, [ ] dependency audit, [ ] agents loopback-bound, [ ] secret rotation.
  - Line 43-45 stale sub-bullet ("Not done yet: plain sqlite3") contradicts the same file's checked checklist item; the checklist and code are current.
- `/home/username/workspace/offlinePOS/docs/WINDOWS_TEST.md`: single-operator Windows test recipe; states entering an Odoo login on-device is local-test-only, fleet points at a backend.

## 2. Local store: lib/core/db

- Engine: raw `sqlite3` package over **SQLCipher** (`sqlcipher_flutter_libs`), NOT drift/sqflite.
  - `/home/username/workspace/offlinePOS/lib/core/db/database.dart`: `Db.open(path, encryptionKey)` issues `PRAGMA key` first (raw 32-byte hex uses `x'..'` form, no KDF; else passphrase, lines 16-35), proves the key with `SELECT count(*) FROM sqlite_master` before migrating, then WAL + foreign_keys ON. `migrate()` (lines 48-65) runs only unseen migrations inside one BEGIN/COMMIT transaction, rollback on failure.
  - Key management: `/home/username/workspace/offlinePOS/lib/core/db/db_key.dart` (random 32-byte hex, generated once, `Random.secure()`; documented trade: keychain wipe = data permanently unreadable) + `/home/username/workspace/offlinePOS/lib/core/db/secure_key_store.dart` (flutter_secure_storage, key `offlinepos_db_key_v1`, not cloud-synced). Wired in `/home/username/workspace/offlinePOS/lib/main.dart:59-60`.
- Schema: `/home/username/workspace/offlinePOS/lib/core/db/schema.dart`, `version = 13`, `migrations` is a list-of-lists (index i upgrades i→i+1), additive-first policy stated at top.
  - v1: `orders` (uuid PK, device_id, cashier_id, created_at, state, server_id, total, payload JSON), `outbox` (id AUTOINCREMENT, kind, payload_uuid, payload, attempts, last_error, sent_at, created_at; index `(sent_at,id)` for ordered drain; **UNIQUE (kind, payload_uuid)**), `audit_log` (at, actor, event, detail, synced_at).
  - v2: catalogue: `categories`, `products` (price, category_id, barcode, active, sold_by_weight, tax_rate), `modifier_groups`, `modifiers`, `product_modifier_groups`, `catalogue_meta` KV.
  - v3: `users` (id, name, pin_salt, pin_hash Argon2id, role, active), `device_enrolment` KV.
  - v4: outbox dead-lettering (`dead_at`, `dead_reason`).
  - v5: `printers` (name PK, host is only a hint, identity, last_seen_at), `wizard_dismissals` (per wizard per cashier).
  - v6: `print_jobs` (durable receipt spool per printer name), `auth_attempts` (persisted lockout).
  - v7: `odoo_endpoint` single row id=1 (base_url, db, login, **password** kept for single-operator local test only, comment at lines 237-243).
  - v8: `shifts` (opening_float, movements JSON, closing_counted).
  - v9: `pos_tables` (floor plan) + `app_settings` KV.
  - v10: `local_customers` (local uuid id, optional partner_id link).
  - v11: `attendance` (clock in/out, separate from drawer shift).
  - v12-13: table shape / divider geometry.
- Stores (one class per table, synchronous reads): `order_store.dart` (payload-is-truth, `markSynced` goes through `save` to keep columns and blob in agreement, lines 69-81; `drafts()/held()/awaitingSync()/recent()/kitchenTickets()`; `delete` only allowed for draft/held, line 103-105), `catalogue_store.dart` (`replaceAll` all-or-nothing transaction, lines 23-80; staleness via `catalogue_meta.refreshed_at`), `sqlite_outbox_store.dart` (see section 3), `shift_store.dart`, `settings_store.dart` (437 lines of on-device settings: receipt toggles, category colours, kitchen station routing per category/product incl. multi-station, tax matrix per category×order type, 86'd products, favourites, language en/ar), `user_store.dart`, `device_store.dart` (device_id uuid generated on first launch, lines 19-25), `attempt_store.dart`, `print_job_store.dart`, `printer_store.dart`, `table_store.dart`, `customer_store.dart`, `attendance_store.dart`.

## 3. Sync layer: lib/core/sync

- Outbox: `/home/username/workspace/offlinePOS/lib/core/sync/outbox.dart`
  - Ordering: strict FIFO by autoincrement id (`pending` ORDER BY id ASC, store line 30-46); a transient failure **stops the drain** to preserve order (lines 108-110, 148-157).
  - Idempotency: client uuid is identity; `SqliteOutboxStore.append` upserts on UNIQUE(kind, payload_uuid), replacing payload and resetting sent_at/last_error (`/home/username/workspace/offlinePOS/lib/core/db/sqlite_outbox_store.dart:13-27`), so re-queuing never duplicates.
  - Retry: no timed backoff on the outbox itself; retries happen whenever the next drain runs (shift close / manual sync). `maxAttempts = 25` then dead-letter park (`markDead`, lines 148-153); `PermanentlyRejected` parks immediately, queue keeps moving. Parked entries are revivable (`sqlite_outbox_store.dart:82-84`) and surfaced in diagnostics + heartbeat (`dead()`, `deadCount`).
  - Batching: batch size 20, up to `maxBatches = 1000` per drain call (a week's backlog drains in one call, lines 93-118). Note: one HTTP call per order (sender posts `args: [[payload]]`), batching is local pacing only.
  - Missing sender: entry stays pending (never parked), kind recorded in `unhandledKinds` for diagnostics (lines 128-137).
  - Ack + retention: `markSent` timestamps; `pruneSent(olderThan: 7 days)` keeps acked rows a week so duplicate pushes stay recognisable (`sqlite_outbox_store.dart:112-118`).
  - Heartbeat exclusions: `pendingCount`/`oldestPendingAge` exclude `device.status` so a caught-up till reads zero and the outage-age number means the outage (`sqlite_outbox_store.dart:88-137`).
- Sender: **a real Odoo HTTP sender exists**, not just interfaces.
  - `/home/username/workspace/offlinePOS/lib/core/sync/odoo_sender.dart`: JSON-RPC over `/web/session/authenticate` + `/web/dataset/call_kw` against `model='sale.order'`, `method='create_from_offline_pos'` (lines 55-63). Captures the `session_id` cookie from Set-Cookie and replays it (lines 93-100, 161-164). Error taxonomy: socket error / 5xx / 429 / non-JSON (captive portal) / expired session = `TransientSyncError` (retry forever); 4xx / wrong credentials / Odoo error payload = `PermanentSyncError`; per-order `status: 'rejected'` = `PermanentlyRejected` park (lines 104-145, 180-208). `kOfflineTillId` (`--dart-define=OFFLINE_TILL_ID`, default `till-1`) overwrites payload `device_id` so the server routes to the pos.config whose "offline till id" matches (lines 49-53, 111-115).
  - `/home/username/workspace/offlinePOS/lib/core/sync/odoo_wiring.dart`: connects a runtime-configured endpoint to the outbox; registers `order.push` sender that authenticates lazily/on session lapse (lines 63-84); `onOrderBooked` → `OrderStore.markSynced`, `onOrderRejected` → audit record (wired in `main.dart:94-102`). **`audit.push` and `device.status` have no server sink**: registered as local no-op acks with an explicit comment that a dedicated endpoint is the follow-up (lines 46-51). `disable()` unregisters so a mispointed till queues instead of pushing.
  - `/home/username/workspace/offlinePOS/lib/core/sync/http_post.dart`: real dart:io HttpClient POST, 20s connect / 30s response timeout, lower-cased response headers for the cookie.
  - No certificate pinning on the sync API path (pinning exists only on the update channel; SECURITY.md line 17 asks for API pinning: open gap).
- Inbound sync (catalogue pull, not outbound-only): `/home/username/workspace/offlinePOS/lib/core/sync/odoo_puller.dart`
  - Pulls `pos.category`; `product.product` filtered `available_in_pos = true` (display_name, lst_price, pos_categ_ids, barcode, to_weight, taxes_id, product_tmpl_id); `account.tax` percent rates (optional, degrade to 0); `product.modifier.category` + `product.modifier` (optional jouma add-on, degrade to none); `pos.payment.method`; `res.partner` customer_rank>0 limited to 500 (lines 14-91). Maps template-linked modifier groups onto variants (lines 108-135). `CataloguePull.isUsable` refuses an empty pull so a working catalogue is never wiped (lines 226-230).
- Orchestrator: `/home/username/workspace/offlinePOS/lib/core/sync/sync_service.dart`
  - Timer every 20s runs `refresh()` only: probe + catalogue refresh if stale (>6h default); **never drains the outbox** (comment lines 112-116, code 169-201).
  - `tick()`/`flush()` = the batch push: `reconcilePending()` (re-enqueues any paid order missing from the outbox, closing the crash window between order save and enqueue; injected from `main.dart:135-141` using `orders.awaitingSync()` + `toServerPayload()`), then `_queueAudit()` (hands unsynced audit rows to outbox and marks them synced locally), `_queueHeartbeat()` (device.status keyed on device id, replaces), `outbox.drain()`, `pruneSent()`, then catalogue refresh (lines 206-249).
  - Connectivity detection: injected probe = unauthenticated POST to `/web/webclient/version_info` with 6s timeout, statusCode 200-499 counts as reachable (`main.dart:111-124`); drives `ValueNotifier<bool> online` (starts false deliberately) for the sell-screen badge; a successful pull/flush also sets online. `hasDestination`/`undeliverableKinds` distinguish "no server configured" from "offline" for support.
  - Push trigger call sites: shift close `onCloseSync` in `/home/username/workspace/offlinePOS/lib/app/pos_app.dart:1350-1368` (reconcile → count → flush → human message incl. offline case) and Support > Sync now in `/home/username/workspace/offlinePOS/lib/features/support/diagnostics_screen.dart:75`.
- Endpoint config: `/home/username/workspace/offlinePOS/lib/core/sync/odoo_endpoint.dart` single-row store; `OdooEndpointStore.save/load/clear`. Seeded from `--dart-define=ODOO_URL/ODOO_DB/ODOO_LOGIN/ODOO_PASSWORD` only when nothing saved (`main.dart:165-177`); a device-entered endpoint wins.
- Heartbeat payload: `/home/username/workspace/offlinePOS/lib/core/sync/device_status.dart` (device_id, app_version, pending, dead, unsynced_audit, oldest_pending_seconds, catalogue_refreshed_at, last_error, cashier_id, needs_attention = dead>0 or oldest>24h).

## 4. Domain state: lib/domain

- `/home/username/workspace/offlinePOS/lib/domain/order.dart`
  - State machine: `OrderState { draft, held, paid, synced }` (line 18) + `KitchenStatus { pending, preparing, ready, served }`; `OrderType { dineIn, takeaway, delivery }`.
  - Lines capture price/tax/category/name at sale time (immutable unitPrice, taxRate); per-line discount, kitchen note, seat (bill split), course-firing `fireAt`, `printedToKitchen`, `firedStations`.
  - Totals computed on the model: `subtotal`, order `discountFactor`, `total = subtotal*discountFactor + deliveryCost + tip` (line 280), `amountPaid`/`balance` for part-payments, `taxTotal` (tax-inclusive display-only, lines 292-300). `businessDay` derives the trading day.
  - `toServerPayload()` (lines 345-369): folds per-line AND whole-order discounts into line/modifier unit prices, zeroes discount_percent on the wire (double-discount guard), nulls synthetic negative partner_ids (local customers) while keeping name/phone; `toMap()` stays raw so a restored draft isn't discounted twice.
  - `OrderPayment` (methodId = Odoo pos.payment.method id, amount, label); several = split payment; empty = server books cash.
- Transitions live in `/home/username/workspace/offlinePOS/lib/app/pos_session.dart` (the till's synchronous, no-await state machine): `addProduct` (with merge rules, lines 90-137), `hold()` draft→held, `recall()` held→draft, `startFresh` (deletes empty draft so no orphan), `pay()` →paid + `outbox.enqueue('order.push', uuid, toServerPayload())` + audit (lines 322-332), `payShare()` even-split with running balance (held until settled, lines 340-361), `payCheck()` carve lines into a separate paid order that syncs on its own so "the server needs no concept of a split" (lines 518-556), `moveLinesToTable`/`mergeOrderInto` with discount flattening so nothing is discounted twice (lines 562-635), seat/course-firing helpers. paid→synced happens only via server ack (`OdooWiring.onOrderBooked` → `OrderStore.markSynced`).
- Shifts: `/home/username/workspace/offlinePOS/lib/domain/shift.dart` + `/home/username/workspace/offlinePOS/lib/core/db/shift_store.dart`. Entirely local; one open shift at a time (store lines 29-31); cash movements (in/out, expense categories); `closeShift(countedCash)`; X/Z `ShiftSummary` computed from orders (state paid/synced) in the shift window, cash-vs-card separation via catalogue payment methods `isCash` (store lines 72-112; wiring `pos_app.dart:1330-1341`); `expectedCash = float + cashSales + cashIn - cashOut`, variance. Close is permission-gated (Permission.closeShift, `pos_app.dart:1346`) and is THE sync trigger (see 3).
- Business day: `/home/username/workspace/offlinePOS/lib/domain/business_day.dart` 04:00 local cutover, ISO key sent as `business_date`; sales before 4am belong to the previous trading day.
- Catalogue models: `/home/username/workspace/offlinePOS/lib/domain/catalogue.dart` (Product, Category, ModifierGroup/Modifier with fixed/percentage/free price types, PaymentMethod, Customer).
- Identity: `/home/username/workspace/offlinePOS/lib/domain/identity.dart` RFC4122 v4 from `Random.secure()`.

## 5. Multi-device story

**Single-device today.** Evidence:
- No LAN sync / server mediation between tills: zero hits for `ServerSocket|HttpServer|WebSocket|multicast|udp` in lib/ (grep). The only sockets are outbound: TCP 9100 to printers and HTTPS to Odoo/update host.
- Kitchen display is a screen on the SAME till reading the local DB: `KitchenDisplayScreen(load: () => widget.orders.kitchenTickets(), onStatus: ...setKitchenStatus)` (`/home/username/workspace/offlinePOS/lib/app/pos_app.dart:819-822`); `kitchenTickets()` reads local `orders` table (`order_store.dart:85-90`). A separate KDS device would see nothing.
- Orders, floor plan (`pos_tables`), shifts, settings are all in the per-device SQLCipher DB; no replication.
- Multi-till awareness is limited to: per-device uuid `device_id` (`device_store.dart:19-25`) so two tills' orders are distinguishable server-side; `OFFLINE_TILL_ID` routing to a pos.config per till (`odoo_sender.dart:49-53`); `SOLE_TILL` build flag feeding the update gate (a second till lets a mandatory update restart during service, `till_config.dart:41`, `update_gate.dart:174-189`). Fleet mediation ("backend that holds the one Odoo login", remote wipe, device tokens) is documented intent, not code.

## 6. Auth / identity: lib/core/auth

- PIN auth, fully offline: `/home/username/workspace/offlinePOS/lib/core/auth/auth_service.dart`. `unlock(cashierId, pin)` → AuthOk/AuthRejected/AuthLockedOut/AuthMalformed; unknown user answered identically to wrong PIN (no user enumeration, lines 75-81); every outcome audited. `authorizeManager(pin)` = manager-PIN elevation for privileged actions without sign-out (lines 108-118). `enrol()` hashes locally.
- Hashing: `/home/username/workspace/offlinePOS/lib/core/auth/pin_hasher.dart` Argon2id (19 MiB, 2 iterations, OWASP baseline; constant-time compare, lines 29-76); per-user 16-byte salt.
- Lockout: `/home/username/workspace/offlinePOS/lib/core/auth/pin_policy.dart` 4-6 digits, 5 attempts, 5-minute lockout doubling per failure, capped 2h; per cashier; persisted in `auth_attempts` via `SqliteAttemptStore` so force-quit does not reset (`attempt_store.dart`, wired `main.dart:79-86`).
- Enrolment of the till: `/home/username/workspace/offlinePOS/lib/core/auth/bootstrap_cashier.dart` random 6-digit provisioning PIN, regenerated each launch, shown once on the sign-in screen, account id `setup` role manager; ends when a real roster exists. No literal PIN in the binary.
- Roles/permissions: `/home/username/workspace/offlinePOS/lib/core/auth/permissions.dart` Permission enum with stable string keys (apply_discount, void_line, cancel_order, refund, reprint, open_drawer, price_override, close_shift, manage_staff, manage_printers, open_settings, view_reports); role sets stored on disk; anything outside the set falls back to manager-PIN dialog. Roles: cashier/manager (`user_store.dart:20`).
- Device enrolment vs Odoo: `/home/username/workspace/offlinePOS/lib/core/auth/device_token.dart` defines the signed, time-boxed DeviceToken (expiry, renew-7-days-early, server signature) but it is **not wired anywhere** (grep: no usage outside the file and its test; `device_enrolment` table only holds `device_id`). Users do NOT map to Odoo users at all: the till authenticates as the one shared integration login, and `cashier_id` on the order payload is the only who-rang-it record (docs/ODOO_SYNC.md lines 55-61, `order.dart:312-314`). Local cashier ids are till-local strings; a roster sync from the server is anticipated (`UserStore.replaceAll`) but no roster puller exists.

## 7. Audit: lib/core/audit

- `/home/username/workspace/offlinePOS/lib/core/audit/audit_log.dart`: append-only local `audit_log`; `record(actor, event, detail)`; `unsynced()/markSynced()` feed the outbox handover; `recent()` with event/time filters backs the manager audit viewer (`/home/username/workspace/offlinePOS/lib/features/support/audit_log_screen.dart`) and activity report.
- Events recorded (grep across lib): `pin.unlock`, `pin.rejected`, `pin.locked_out`, `sign_out`, `manager.authorized`, `manager.authorization_failed`, `order.paid` (+ split variants), `order.held`, `order.moved`, `order.merged`, `line.voided` (with reason), `order.rejected` (server refusal, `main.dart:100-101`), `receipt.dropped` (spool cap eviction, `pos_app.dart:193-197`).
- Sync: queued as `audit.push` at every flush (`sync_service.dart:143-157`) then marked synced locally, but the registered sender is a no-op (see section 3): the local log is currently the system of record; server-side audit endpoint is an acknowledged follow-up (`odoo_wiring.dart:46-51`).

## 8. Printing: lib/core/printing

- Transport: raw **ESC/POS text bytes over TCP 9100** on the shop LAN (no rasterising, no cloud, works during internet outage). `/home/username/workspace/offlinePOS/lib/core/printing/printer_transport.dart`: `TcpPrinter` (5s timeout to fail fast, 1 quick retry after 300ms for mesh-wifi roaming, socket always closed, lines 28-87); `FallbackPrinter` tries printers in order; `SpooledPrinter` wraps a transport with a durable queue.
- Queue/retry: spool = `SpoolStore`; production uses `/home/username/workspace/offlinePOS/lib/core/db/print_job_store.dart` (SQLite `print_jobs`, per printer NAME, survives nightly restart). Cap 100 jobs; evictions audited, never silent (`onDropped`). `flush()` retries oldest-first, stops at first failure to preserve ticket order, re-entrancy guarded (`printer_transport.dart:179-199`); flushed automatically on a 30s background timer (`pos_app.dart:206, 215-222`) and from the Support screen. `sendNow()` bypasses the spool for cash-drawer kicks (must not replay).
- Addressing: printers are remembered by NAME, never address. `/home/username/workspace/offlinePOS/lib/core/printing/printer_registry.dart`: resolve name → last-known host probe → subnet sweep (`printer_discovery.dart`, TCP-connect scan of the /24) → disambiguate by learned identity (reverse-DNS hostname), 4s resolve budget, 45s failed-sweep backoff, refuses to guess between unidentified candidates (lines 232-279). Persisted to the `printers` table via `printer_store.dart`; `registry_printer.dart` builds a socket per job so a moved lease still prints.
- Documents: `/home/username/workspace/offlinePOS/lib/core/printing/receipt_builder.dart` (42-col customer receipt, injected money formatting, toggles from settings), `kitchen_ticket.dart` (KOT: no prices, big names, modifiers/notes, station label, re-fire prints only new lines), `escpos.dart` (code-page mapping so Arabic/euro/smart-quotes degrade to a placeholder instead of throwing pre-spool). Kitchen routing per category/product to multiple stations lives in `settings_store.dart` (lines 154-292); course firing (`fireAt`) fires from the 30s timer (`pos_app.dart:228-245`).

## 9. Config / onboarding

- Build-time: `/home/username/workspace/offlinePOS/lib/core/config/till_config.dart` from `--dart-define`: SHOP_NAME, SHOP_TAX_ID, RECEIPT_FOOTER, UPDATE_MANIFEST_URL, UPDATE_PUBLIC_KEY, UPDATE_CERT_PINS, SOLE_TILL. Absent = feature off, never a guessed default; update channel only assembled when url+key+pins ALL present (`hasUpdateChannel`, lines 72-75; enforced `main.dart:213-243`). Plus APP_VERSION (`main.dart:46`), OFFLINE_TILL_ID (`odoo_sender.dart:52`), optional ODOO_* endpoint seed (`main.dart:165-173`).
- First run on a till: DB + key created; device_id uuid generated; BootstrapCashier prints a one-time random manager PIN on the sign-in screen; catalogue is empty until a server is configured. Server URL/tenant entered at runtime on `/home/username/workspace/offlinePOS/lib/features/settings/server_settings_screen.dart` (URL, database, login, password; amber banner: "For local testing. A live fleet points at a backend and never stores an Odoo password on the till", lines 77-86); saving rewires the live sender immediately (`onSaved: widget.odoo.configure`, `pos_app.dart:1320-1325`) so pre-config queued sales drain without restart. Catalogue then arrives via the puller on the next refresh/flush.
- Coach onboarding: `/home/username/workspace/offlinePOS/lib/core/onboarding/wizard_id.dart` (frozen keys: first_sign_in, first_sale, modifiers, diagnostics, printer_setup) + `wizard_store.dart` (per-wizard per-cashier dismissals in DB; new wizards show once even to veterans) + overlay UI `/home/username/workspace/offlinePOS/lib/features/onboarding/wizard_overlay.dart`.

## 10. Updates: lib/core/updates

- `/home/username/workspace/offlinePOS/lib/core/updates/update_service.dart`: check → verify signed manifest → gate → download → sha256 vs manifest → stage to app-private dir → **re-read and re-hash the file at install time** (hours can pass while gated; lines 285-315) → platform installer. Https-only manifest URL enforced in the constructor (lines 108-115). Withdrawn/changed rollout deletes the staged file (lines 165-172). Older-than-current manifests ignored (anti-downgrade, lines 175-183). Server never chooses the file path (`_fileNameFor`, lines 349-358).
- Trust chain: `manifest_signature.dart` Ed25519 over the exact manifest bytes (`{"manifest": b64, "signature": b64}` wrapper so no re-serialisation ambiguity); `update_transport.dart` `PinnedUpdateTransport` requires >=1 sha256 DER cert pin, no "empty = unpinned" mode; `update_manifest.dart` semver-aware `AppVersion` ordering ("1.10.0" > "1.9.0"), `isMandatoryFor` mandatory-below threshold; `update_storage.dart` FileUpdateStorage in app support dir.
- Gate: `update_gate.dart` blockers: **unsyncedSales (never overridden at any severity)**, rejectedSales (needs support), saleInProgress, serviceHours (default 08:00→04:00 wrap, matches business-day cutover), soleTillInService (mandatory overrides the clock only if another till can sell). TillState is built from the same DeviceStatus numbers the heartbeat reports (`main.dart:229-236`) so gate and support never disagree. Runs last on the 30s background timer (`pos_app.dart:221`).

## 11. What tests actually prove (test/sync, test/db, test/staging + sync-relevant test/core)

- `/home/username/workspace/offlinePOS/test/core/outbox_test.dart`: FIFO preserved behind a stuck entry; replay-safe via client uuid; entry with no sender kept (never parked) and goes out once a sender appears; permanent rejection parks while the queue keeps moving; transient failure stops the drain preserving order; repeated failure eventually parked (maxAttempts); big backlog drains in one call.
- `/home/username/workspace/offlinePOS/test/core/odoo_sender_test.dart` (208 lines): authenticates and keeps the session cookie; wrong creds permanent; dead socket transient; 5xx/429 transient vs 4xx permanent; captive-portal HTML transient; push carries the client uuid; pre-auth push is transient; expired-session error payload clears the login and retries; module statuses: created = ack, duplicate = ack, rejected = park; payload field completeness.
- `/home/username/workspace/offlinePOS/test/core/sync_service_test.dart`: reconcile re-queues a paid sale missing from the outbox; tick drains + refreshes catalogue; failures recorded not thrown; **empty pull never wipes the catalogue**; **refresh never drains the outbox** (no off-shift pushes); probe-offline skips pull; flush success/failure drives the online flag; fresh catalogue not re-pulled.
- `/home/username/workspace/offlinePOS/test/core/heartbeat_test.dart`: heartbeats replace instead of piling up during an outage; rejected sale sets needs_attention; audit handed to outbox; oldest-pending age excludes the heartbeat row (and a heartbeat-only till is not an outage).
- `/home/username/workspace/offlinePOS/test/core/puller_test.dart`: many2one `[id,label]`/false unwrapping; template→variant modifier-group mapping; price types; empty pull unusable.
- `/home/username/workspace/offlinePOS/test/sync/odoo_wiring_test.dart`: unconfigured wiring keeps sales queued; configure registers a sender that authenticates then books; **audit entries drain locally and are never posted as sale orders**; disable() stops pushing. `/home/username/workspace/offlinePOS/test/sync/odoo_endpoint_test.dart`: endpoint round-trip, single row, incomplete = unconfigured.
- `/home/username/workspace/offlinePOS/test/db/store_test.dart`: migrations reach current version, idempotent; **a till holding unsynced sales keeps them across a schema upgrade**; order round-trips with modifiers; unpaid order restorable (crash recovery); upsert not duplicate; outbox durability, replace-on-requeue, FIFO, drains through Outbox after reconnect, prune honours 7-day retention.
- `/home/username/workspace/offlinePOS/test/db/encryption_test.dart` (Linux-only, real libsqlcipher via `test/db/sqlcipher_loader.dart`): key generated once and reused; **ciphertext does not contain plaintext**; **wrong key rejected, right key still reads**; control test proves the no-key file DOES leak plaintext.
- Other db tests: `auth_attempts_test.dart` (lockout survives force-quit, escalation, cap, per-cashier), `catalogue_test.dart` (offline reads, barcode, modifier rules enforced on device, failed refresh keeps old catalogue, staleness), `shift_store_test.dart` (X/Z, card excluded from drawer cash), `table_store_test.dart`, `attendance_store_test.dart`.
- `/home/username/workspace/offlinePOS/test/staging/*` — real-Odoo integration tests, skipped unless STAGING_URL/DB/LOGIN/PASSWORD dart-defines are set (never run in CI):
  - `staging_orderpush_test.dart`: drives the REAL OdooWiring/OdooSender: enqueue a paid order, drain, then verifies in Odoo that a `sale.order` exists keyed by `offline_uuid` with `state == 'sale'` (confirmed, reaches sales reports) and `offline_device_id` (server-side custom fields confirmed).
  - `staging_sync_test.dart`: real sender books an order over HTTPS against a real build (STAGING_PRODUCT/STAGING_CONFIG).
  - `staging_payment_test.dart`: a chosen payment method books that method in Odoo. `staging_discount_test.dart`: a 25% order discount books the reduced total. `staging_pull_test.dart` + `staging_fullpath_test.dart`: configure → authenticate → pull → store → read returns products.
- Also present but out of scope here: test/ui, test/features (28 screen tests), test/printing (8 files), test/updates, test/onboarding, test/domain (business_day cutover, order totals/payload), test/app (pos_session, split payments).

## Cross-cutting gaps worth flagging to synthesis

1. `audit.push` / `device.status` have no server sink (local no-op ack, `odoo_wiring.dart:46-51`); heartbeat and remote audit are design promises only.
2. DeviceToken enrolment (ARCHITECTURE.md auth layer 1) is an unwired class; the real auth is the shared Odoo login whose password sits in the (SQLCipher-encrypted) `odoo_endpoint` table, explicitly labelled local-test-only on-screen and in docs.
3. No cert pinning on the Odoo sync transport (only the update channel is pinned) and SECURITY.md's "backend rules deny by default / tenant-scoped" checklist item is open, since server-side enforcement lives in the pos_offline_sync module outside this repo.
4. Outbox retries have no timed backoff loop; a failed batch waits for the next shift close / manual Sync now (by design per ODOO_SYNC.md, but "retry forever" in docs means "retry on next trigger").
5. Single-device: no till-to-till or till-to-KDS sharing exists today (section 5).
6. ARCHITECTURE.md's encryption paragraph and README's "Not built yet" list are both stale relative to code.

---

# DETAILED FINDINGS: Dishflow POS: Backend + Data Architecture Inventory

# Dishflow POS: Backend + Data Architecture Inventory

Repo: `/home/username/workspace/Dishflow-pos` (branch `Test`). All paths below are relative to this root unless prefixed with `/`.

---

## 1. Firebase connection layer

### Initialization (`lib/main.dart`)
- `_bootstrapApp()` at `lib/main.dart:122-264`:
  - Default options from `lib/firebase_options.dart` (generated, projectId `pos-test-70970` per `firebase.json` flutter block).
  - Dev-only project switcher (`lib/main.dart:142-153`, tree-shaken in release) via `lib/core/dev/dev_firebase_selector.dart`.
  - RM-web project switcher when host is `reports.code-solution.org` or `?mode=rm-web` (`lib/main.dart:157-170`) via `lib/core/rm_web/rm_web_firebase_switcher.dart`.
  - `Firebase.initializeApp(options)` at `:172`, tolerant of `duplicate-app` on web hot restart.
  - **Firestore offline persistence enabled explicitly**: `persistenceEnabled: true, cacheSizeBytes: CACHE_SIZE_UNLIMITED` at `lib/main.dart:181-186` (IndexedDB on web). Web also requests persistent storage (`requestPersistentStorage()` at `:189-191`, from `lib/utils/storage_persist.dart`) so the browser does not evict offline orders.
  - A **second named Firebase app `'menu'`** is initialized at `lib/main.dart:203-214` with the same options and its own unlimited persistent cache. QR-menu and ecommerce order services read through it.
  - Emulator switch: `USE_FIREBASE_EMULATOR` env → Firestore emulator `localhost:8181` (`lib/main.dart:199-202`).
  - Comment at `:197-198`: a startup `disableNetwork()` was removed; "print-time safety" moved to Firestore REST (see print section).

### Auth mode
- **Anonymous Firebase Auth**, added recently: `lib/services/firebase_identity_service.dart` (`ensureSignedIn()` called at `lib/main.dart:219`). Signs in BOTH the default app and the named `menu` app (`firebase_identity_service.dart:31-36`), 8s timeout, deliberately soft-fails offline (`:57-68`). Doc comment (`:7-16`) states: until this ships to all tills, rules must stay world-open because `request.auth` was always null.
- There is **no Firebase email/custom-token auth**. Staff identity is an Odoo login + PIN quick-login stored in Firestore `pos_users` (see security). The print agents authenticate to Firestore with **nothing** (REST with public web API key).

### Per-tenant Firebase projects
- One Firebase project per branch (tenant). Config sets in `lib/firebase_configs/<client>/firebase_options.dart` for 13 clients: `balkans_madente, balkanz_gym, balkanz_nasr, balkanz_zayed, balkns_copy_live, balkns_sahel_one, balkns_sahel_two, cai_gardennasrcity, cai_madenty, cai_sahel_one, cai_sahel_two, cai_sawspark, cai_straubmall, dev`.
- Known projectIds mapped in `lib/services/multi_firebase_service.dart:32-78`: `pos-test-70970` (Balkanz Nasr), `pos-juma` (Balkanz Gym), `pos-admin-dashboard-bf6d9` (Cairo Caizer Madinaty), `zayed-city-afdb2` (Balkanz Zayed), `odc-chat` (Dev/Test). More projectIds in `firebase.json` flutter block: `balkns-sahel-brunch-one/tow`, `cai-sahel-brunch-one`, `cai-shel-brunch-tow`.
- Deploy: `deploy_all.ps1:9-26` copies `lib/firebase_configs/<client>/firebase_options.dart` over `lib/firebase_options.dart`, `flutter build web`, then uploads to per-client cPanel dirs under `public_html/<domain>` (domains like `cai.code-solution.org`, `blkan.code-solution.org`, `reports.code-solution.org`). `deploy_configs/*` dirs exist per client (dev one is empty).
- `deploy_firestore_indexes.sh` fans `firebase deploy --only firestore:indexes` out to every unique projectId (per `docs/STATE.md:24,39`).
- Runtime custom config also possible: `lib/services/firebase_config_service.dart` stores an arbitrary Firebase options JSON in SharedPreferences (multi-tenant escape hatch).

---

## 2. Firestore data model (collections)

Enumerated from `grep collection('...')` across `lib/`. There is **no top-level tenant key inside a project**; the tenant IS the Firebase project. Row-level scoping inside a project is by `odooConnectionId` and `branchId` fields (enforced in queries, NOT in rules; see `firestore.rules:41-47` comment).

### Core sales pipeline
- **`sales`** (96 usages, the heart of the system). Writer: `lib/services/firebase_sales_service.dart`.
  - `saveSaleToFirebase` doc shape at `firebase_sales_service.dart:120-192`: `odooConnectionId/Name, odooOrderId/Name, userId, userName, amount, itemsCount, paymentMethod (sanitized via _safePaymentMethodLabel :21-51), timestamp (serverTimestamp), syncedToOdoo, branchId/Name, orderType, status, partner_name, driver_id/name/phone, customer_name/phone, delivery_address, delivery_company_order_no, tableNumber, payments[], amountUntaxed, amountTax, shift, businessDateKey, sessionId, sessionDate, items[] {productId, productName, quantity, unitPrice, totalPrice, itemDiscount*, pos_category_name, modifiers[]}`.
  - Pending (offline, not yet in Odoo) sales: `savePendingSaleToFirebase` (`:229`) writes `syncedToOdoo:false`, `odooOrderId: 'pending_N'`; `updatePendingSaleToSynced` (`:429`) flips them after Odoo accepts. `getMaxPendingOrderNumber` (`:203`) recovers the pending counter after cache wipes (forced `Source.server`).
  - Other fields written elsewhere: `kitchenStatus` (kitchen display, `lib/features/kitchen/presentation/kitchen_display_screen.dart:51-57`), `etaSubmitted` (`markSaleAsEtaSubmitted` `:2800`), `delivery_status`, `cashier_shift_id`.
  - Readers: home dashboard, reports (dozens of query paths `:851-2734`), delivery board (`delivery_orders_screen.dart` reads `sales`, filters by `driver_id`), flash report realtime (`lib/features/reports/presentation/flash_report_screen.dart:210,231` uses `.snapshots()`), kitchen display realtime (`kitchen_display_screen.dart:42-48`: `where('timestamp' >= startOfDay).snapshots()`).
  - Writes are single `add()`/`update()` per order (not transactional); bulk deletes use chunked `WriteBatch` (`:2756-2790`).
- **`active_sessions/{connectionId}`**: one doc per Odoo connection. Writer/owner `lib/services/active_session_service.dart`. Open is a Firestore **transaction** (`:348-420`) with deterministic `sessionId = session_YYYY-MM-DD_<shift>_<epochOfShiftStartUTC>` (`composeSessionId :93-104`, epoch is shift start 06:00/14:00 UTC-pure to survive device timezone skew, `:105-121`). Doc fields: `sessionId, status(open/closed/auto_closed), shift, businessDateKey, connectionId, openedBy/Name/Login, openedAt, closedAt, closedBy, reopenCount, reopenedAt/By, closedReason`. Case C auto-closes a stale session when the date/shift rolls over. There is **no `sessions` collection**; a session is emergent from `sales.sessionId` + `cashier_shifts` (`docs/STATE.md:40`).
- **`cashier_shifts`** (13 usages): per-cashier shift docs incl. `isLocked`, `sessionId` (writer `lib/services/cashier_shift_service.dart:258,310,335`; realtime listener at `:404` and in `cashier_selection_dialog.dart:212`). Composite index `sessionId+isLocked` exists.
- **`open_orders`** + **`counters/order_global_seq`**: dine-in "sent to kitchen" orders. `lib/services/open_order_service.dart`. Order numbers are **local-first**: SharedPreferences counter incremented instantly, then fire-and-forget transaction raises the global Firestore counter to max (`:86-95`); offline fallback seeds from a timestamp; a per-tab 3-digit `_sessionTag` (`:29-31`) makes numbers collision-safe across tills (`DDMM-SEQ-TAG`). Realtime `.snapshots()` at `:288` and in `open_orders_screen.dart:259`.
- **`suspended_orders/{connectionId}_{orderId}`**: full `OfflineOrder` JSON in a `data` field plus header fields (`lib/services/firebase_suspended_order_service.dart:28-60`). Hybrid model: local write first, fire-and-forget Firebase upsert; UI reads the Firebase stream with local fallback (`:196` snapshots). Resume uses a **transaction lock** via `resumedBy/resumedByName` (`:147-165`). Batch cleanup `:120`.
- **`deleted_kitchen_lines`**: audit of lines removed after send-to-kitchen (`firebase_sales_service.dart:700-746` writer + reader).
- **`order_actions_log`**: per-branch order action audit (indexed `branchId+at`).
- **`session_adjustments`**: manual payment-method totals per session close, one `add()` per close (`lib/services/firebase_session_adjustment_service.dart:15-40`: `sessionId, machineId, odooConnectionId/Name, userId/Name, totalSales, adjustments[], createdAt`). Also a source for payment-name resolution (`docs/ODOO_TOKEN_AND_PAYMENT_NAMES.md:74-105`).
- **`dashboard_stats`**, `counters`, `menu_counters`, `ecommerce_counters` (mobile app side): derived counters. `updateDashboardStats` at `firebase_sales_service.dart:2072`.

### Identity / config / permissions
- **`odoo_connections`**: pre-login lookup of the tenant's Odoo server. Shape in `lib/services/firebase_permission_service.dart:10-77` (`OdooConnectionInfo`): `name, url, database, isActive, subscriptionStart/End`. Read pre-auth with `where('isActive'==true).limit(1)` (`:493-531`). World-readable by design.
- **`pos_users/{odooUserId}`**: the credential + authz store: role, branchId, permissions, `rm_accessible_projects` (multi-tenant RM), plus quick-login secrets `pinHash/pinSalt/odooPasswordEnc` (written by `lib/services/quick_login_service.dart:183-189`; hard-coded AES key at `:46-47` per `SECURITY_REVIEW.md` H1). Realtime per-user listener `firebase_permission_service.dart:1223`.
- **`roles`**, **`branches`** (13 usages; `branches/{branchId}.name` is the authoritative branch name, `docs/STATE.md:43`), **`settings`** (35 usages; notably `settings/app_config` with 5+ separate realtime listeners in `lib/services/local_storage_service.dart:1121-1280`, and `settings/print_routing` for terminal→printer routing `lib/services/print_routing_service.dart:9-12,75-80`), **`payment_methods`**, **`pos_terminals`** (terminal auto-registration `print_routing_service.dart:52-58`), **`managers`**, **`users`**.

### Menu / kiosk / ecommerce (named app 'menu')
- **`menu_catalog`** (`data` + `settings` docs): public-read QR menu catalog (`lib/services/firebase_menu_service.dart:23-60`).
- **`menu_orders`**: customer-created orders (public create). Cashier claim is a **transaction** `tryClaimOrder` (`firebase_menu_service.dart:191-215`) locking on `receivedBy`; status flow `pending→received→paid→completed`. Realtime `watchPendingOrders()` (`:157-162`) and per-order customer tracking `watchOrder` (`:166`).
- **`menu_counters/{YYYY-MM-DD}`**: transactional daily order number (`:139-154`).
- **`ecommerce_orders`**: written by the separate mobile app (`dishflow-kingdom-multiresturant-mobile`), consumed by POS via `lib/services/firebase_ecommerce_order_service.dart` (same claim pattern, soft-complete only because an external backend listens on status; deletion forbidden). Full field contract in `docs/ECOMMERCE_DELIVERY_INTEGRATION.md` (status map `pending→CONFIRMED, received→PREPARING, paid→READY, completed→DELIVERED`).
- `menu_order_link_service.dart` / `ecommerce_order_link_service.dart` bridge claimed orders into the POS cart and mark completed at checkout.

### Delivery / logistics
- **`drivers`** (+ subcollection `drivers/{id}/orders`, which is **write-only dead data**, no reader, `docs/STATE.md:42,84`), **`shipping_companies`** (+ `drivers`, `product_prices` subcollections), **`shipping_zones`**, **`delivery_customers`**, **`customers`**.
- Assigned-driver source of truth is `sales.driver_id`, not the drivers subcollection (`docs/STATE.md:42`).

### Printing / agents
- **`print_jobs`**: Firestore print queue (fallback path). World read/write in rules. Client enqueue via Firestore REST is currently a **stub returning false** (`lib/services/print_job_service.dart:14-52`), so the app always uses direct HTTP; the agents still poll the collection.
- **`agent_heartbeat/{nodeId}`**: POSPrint agents write heartbeat (LAN IPs + port) every 5s; POS devices discover agents from it (`lib/services/agent_discovery_service.dart:10-18,55-60`).
- **`printer_settings`**, **`printers`**: printer configs (`firebase_printer_service.dart`).

### Inventory / catalog / misc
- **`product_prices`**, **`pricelists`** (batched writes `lib/services/pricelist_service.dart:108,303`), **`additions`** (product modifiers, `firebase_permission_service.dart:1113-1213`), **`modifier_option_overrides`**, **`kitchen_product_categories`**, **`custom_categories`** (via `_collection` var), **`product_groups`**, **`pos_stock`**, **`warehouse_cache`**, **`expenses_cache`**, **`discounts`**, **`coupons`/gift cards** (`coupon_service.dart`, realtime `:99,239`), **`loyalty_config`**, **`loyalty_transactions`**, **`tables`** + **`table_settings`** (realtime table map, `firebase_table_service.dart:336-375`, batched layout writes `:393,637,681`), **`attendance`** + **`fingerprint_templates`** (base64 fingerprint templates! `lib/services/firebase_attendance_service.dart:17-47`), **`manager_attendance`**, **`ai_chat_history`**, **`orders`** (menu/kiosk legacy).
- `withConverter` is **not used anywhere** (grep returned nothing); all mapping is hand-rolled `Map<String,dynamic>`.

### Indexes
- `firestore.indexes.json`: ~70 composite indexes, overwhelmingly on `sales` (every report filter combo of `odooConnectionId, branchId, sessionId, sessionDate, businessDateKey, syncedToOdoo, status, orderType, shift, userId, timestamp, createdAt, etaSubmitted`), plus `open_orders`, `suspended_orders`, `cashier_shifts(sessionId+isLocked)`, `deleted_kitchen_lines`, `discounts`, `order_actions_log`. Deployed to 13 projects (`docs/STATE.md:24`).

---

## 3. State flow

### Order lifecycle (till → cloud → other devices)
1. Checkout writes **locally first**: `OfflineOrderService.saveOrderLocally` (`lib/services/offline_order_service.dart:580`) into SharedPreferences (desktop/mobile) or IndexedDB via `LargeKvStore` on web (`lib/services/large_kv_store.dart:1-25`, conditional import; localStorage 5MB quota was overflowing). `InstantOrderService.saveOrderSync` (`lib/services/instant_order_service.dart:21-36`) returns to the UI in ~1ms and persists in background.
2. **AutoSyncService** (`lib/services/auto_sync_service.dart`) runs every 1 minute (`:57`, timeout 50s `:59`), pushing unsynced local orders to Firestore `sales` as pending docs (`_doSync` `:193-330`, marks `firebaseSynced` locally on success, enriches payment names from cache `_sanitizePayments :19-49`). Reconcile pass every 10 min (`:344`).
3. **Odoo is synced separately and mostly at session close**: `OdooApiService.createSaleOrder` (`lib/services/odoo_api_service.dart:2084-2233`, POST `/api/sale/order/create`, with timeout recovery via `clientOrderRef` `:2228-2232`) is called from `session_sync_screen.dart:396`, `end_of_day_closing_screen.dart:533`, `past_orders_screen.dart:339`, `session_close_screen.dart:1424,2333,2502`; each success calls `updatePendingSaleToSynced` to flip the Firestore doc (`syncedToOdoo:true`, real `odooOrderName`).
4. So the flow is: **till-local → Firestore (backup + cross-device realtime) → Odoo (batch, human-triggered)**. Firestore is the operational hub; Odoo is the ledger of record after close.

### Realtime vs polled
- Realtime `.snapshots()` listeners (~43 sites, list from grep): kitchen display (today's `sales`), flash report, home screen alerts, open orders, suspended orders, tables + table config, menu/ecommerce orders, cashier shifts, `pos_users` (permission changes), `settings/app_config` (5 listeners), customer display doc, drivers, shipping, coupons, `active_sessions/{connectionId}` (force logout).
- Polled: print agents poll `print_jobs` every 10s (`print_agent_setup/print_agent.js:37` POLL_MS=10000; pos_print_mesh default 2000ms); AgentDiscovery refreshes heartbeats every 15s (`agent_discovery_service.dart:47-51`); AutoSync every 60s; kitchen screen also repaints on a 30s timer.
- POS→kitchen display propagation = write to `sales` → other device's snapshot listener. POS→admin/RM dashboard = same Firestore project read from the RM web portal (reports.code-solution.org) or `rm_mobile_app/`.

### Cross-till conflict handling
- Session open: Firestore **transaction** + deterministic session id (see above) prevents split/duplicate sessions (`active_session_service.dart:348-420`).
- Force logout fan-out: `SessionStatusWatcher` (`lib/services/session_status_watcher.dart:41-72`) listens on `active_sessions/{connectionId}`; on `status=='closed'` fires `forceLogoutTick`; `_ForceLogoutGate` in `lib/main.dart:518-609` tears down local state on all devices except the closer (`ActiveSessionService.isCloser`, `main.dart:549-552`).
- Claim locks: menu/ecommerce orders claimed via transaction on `receivedBy`; suspended orders resume-locked via transaction on `resumedBy`.
- Counters: order sequence is local-first with monotonic max-merge transactions (never decrements, `open_order_service.dart:86-95`), plus per-tab session tag to avoid two-till collisions; offline order counter recovered from Firestore max after cache clears (`offline_order_service.dart:529,545,568`).
- Deletion tombstones for offline orders and suspended orders prevent resurrect-on-sync (`offline_order_service.dart:491-513, 1145-1172`).
- No CRDT/merge for concurrent edits of the same doc: last write wins (e.g. `sales.kitchenStatus` update is a blind `update()`).

### Offline behaviour
- Firestore unlimited local cache + queued writes = the till keeps selling, printing (local agent path), suspending, and reading menu/permissions from cache. Sentry deliberately drops Firebase `unavailable/offline` noise (`lib/main.dart:103-113`).
- On reconnect: Firestore flushes queued writes; AutoSync pushes anything still local; `restoreFromFirebaseIfEmpty` (`offline_order_service.dart:1466`) repopulates a wiped till from `sales` pending docs; `rescueSyncAllBuckets` (`:874`) re-syncs stranded per-user buckets.
- First-launch-offline caveat: no anonymous identity yet → tightened rules would refuse the till until it sees the network once (`firebase_identity_service.dart:59-65`).

---

## 4. Security

- **Effective model (`firestore.rules`, deployed): world read/write.** Catch-all `match /{document=**} { allow read, write: if true; }` at `firestore.rules:97-99` grants everything to anyone with the projectId (which ships in the client bundle). Named rules above it are cosmetic. Explicit public reads: `odoo_connections, pos_users, settings, roles, menu_catalog`; public read+write: `shipping_zones, print_jobs, agent_heartbeat, shipping_companies, menu_orders, menu_counters`.
- `firestore.rules.step1` (`:21-37`): planned first tightening, single `isApp()` gate (`request.auth != null` via anonymous sign-in) over everything; header comments (`:1-19`) explain the ordered rollout and why `.proposed` would be an outage (names 20 collections while the app uses 44).
- `firestore.rules.proposed` (`:13-71`): eventual default-deny per-collection ruleset; blocked on the print agent getting an auth identity (H2) and keeps `odoo_connections` + QR menu public.
- `storage.rules:7-11`: `session_reports/*` public read + unauthenticated PDF writes <10MB (for WhatsApp/WAAPI fetch); everything else denied (`:14-16`).
- `SECURITY_REVIEW.md` verdict: **CRITICAL, do not go live** (4 Critical: world-open DB C1, committed SMTP password C2, open email relay C3, public storage C4; 5 High incl. recoverable Odoo passwords in `pos_users` H1, unauthenticated print agent on 0.0.0.0 H2, unsigned auto-update RCE H3).
- `FirebaseIdentityService` + git log (recent commits about permissions cache/deny defaults) show step 1 is in flight on branch `Test`.

---

## 5. Cloud Functions (`functions/index.js`, 159 lines total)

Only two functions, both region `europe-west1`, both `invoker: 'public'`:
1. **`sendEmail`** (callable v2, `:7-100`): nodemailer SMTP relay through `mail.code-solution.org:465` (`SMTP_*` env, fail-closed if `SMTP_PASS` unset `:36-42`, TLS verify on `:53-55`). Accepts `to/subject/htmlBody/textBody/cc/bcc/attachments(base64)`. **No auth check.** Called from the app via `FirebaseFunctions.instanceFor(region 'europe-west1').httpsCallable('sendEmail')` (`lib/services/email_service.dart:67-68`) for emailed reports.
2. **`etaProxy`** (HTTP, `:108-159`): server-side CORS-bypass proxy for the Egyptian Tax Authority; allowlists `eta.gov.eg` hosts only (`:133-135`), 25s timeout, wraps upstream as `{status, data}`. Exposed through the Hosting rewrite `/api/etaproxy` (`firebase.json` hosting block); consumed by `lib/services/eta_service.dart:414-430` (`https://<projectId>.web.app/api/etaproxy`). `hosting_eta_stub/index.html` is a stub hosting site to carry that rewrite.
- **No Firestore triggers, no scheduled functions, no aggregation/counter functions.** All derived state (dashboard_stats, counters) is computed client-side.

---

## 6. `pos_backend/` (experimental parallel backend, NOT the production path)

- FastAPI + SQLAlchemy(async) + PostgreSQL (asyncpg) + Alembic + APScheduler. `pos_backend/app/main.py:1-123`: lifespan inits DB, registers interval jobs `scheduled_product_sync` and `scheduled_order_sync` (paused unless `auto_sync_enabled` setting true).
- Config `pos_backend/app/core/config.py`: Postgres `pos_system` DB, Odoo at `http://localhost:8072` db `pos_odoo18_test` (JSON-RPC creds in env), JWT auth (HS256, 24h), CORS localhost.
- Endpoints (`pos_backend/app/api/routes.py`, 1222 lines): `/auth/login`, `/auth/me`, `/products`, `/categories`, `/branches` CRUD + members, `/roles` CRUD, `/users`, `/pricelists` CRUD + rules + bulk-adjust + resolve, `/orders` CRUD + status, `/audit-logs`, `/settings`, `/sync/full|products|categories|orders|logs|auto-status|toggle-auto`, `/health`.
- Models (`pos_backend/app/models/models.py`): branches, roles, users, categories, products, pricelists, pricelist_rules, orders (with `client_uuid` idempotency migration `migrations/2026-07-28_orders_client_uuid.sql`), audit_logs, settings, table_sections, sync_logs.
- Odoo bridge (`pos_backend/app/services/odoo_sync.py`): JSON-RPC (`/jsonrpc`, `common.authenticate` + `object.execute_kw`); pulls products/categories/users, pushes completed orders as **`pos.order` create** (`:348-388`).
- Flutter client: `lib/services/pos_api_service.dart` (Dio, Bearer JWT, base `http://localhost:8000/api`, doc comment says "Replaces direct Firestore/Odoo calls for persistent data storage"). Initialized at startup (`lib/main.dart:225-226`) and referenced in ~10 screens, but the live sales pipeline (sections 2-3) still runs on Firestore + the Odoo addon REST API. Role: an in-progress migration/second backend, effectively dormant relative to Firestore.

---

## 7. Print pipeline (`pos_print_mesh/` + `print_agent_setup/` + services)

- **Transport is dual-path: direct LAN HTTP first, Firestore queue as fallback/secondary.**
- Agents:
  - `pos_print_mesh/` ("POSPrint", Dart-compiled `POSPrint.exe` v2.0): watches Firestore `print_jobs` via REST polling (default 2s) AND serves HTTP on `0.0.0.0:9199` (`/ping /printers /status /print/raw /print/kitchen /print/receipt /print/sub-receipt`, README:80-140). Job reliability: claim with `claim_timeout_ms` 60s stale requeue, `max_retries` 5, `retry_delay_ms` 15s, printer fallback routing, per-printer roles (receipt/kitchen/sub_receipt/delivery). Config `pos_print_mesh.json` (project_id `pos-test-70970`, `firebase_api_key` required in prod = plain web API key, no auth identity).
  - `print_agent_setup/print_agent.js` (legacy Node agent v2.9.1): same port 9199, hard-coded PROJECT_ID + web API key (`:33-34`), polls every 10s (`:37`), `AGENT_ID = host-pid` to avoid double print, job expiry 10 min (anti flood-print after outage), stale claim 2 min, per-printer-IP TCP mutex queue (`:57+`), hourly self-update that downloads and silently runs an installer (SECURITY_REVIEW H3). Windows installer via `installer.iss`; `latest.json` feeds auto-update.
  - `zk_fingerprint_agent.py`: Flask on port 9201 for ZKTeco ZK8500R fingerprint reader (enroll/verify), used by attendance; templates stored base64 in Firestore `fingerprint_templates`.
- App-side dispatch: `ReceiptPrintService` (`lib/services/receipt_print_service.dart:25-27`): Web renders Arabic to raster → `/print/raw`; desktop direct TCP ESC/POS (`escpos_tcp_service.dart`) or agent JSON. Routing per terminal from `settings/print_routing` + `pos_terminals` (`print_routing_service.dart`). Discovery/failover order in `agent_discovery_service.dart:177-222`: 1) `127.0.0.1:9199`, 2) best mesh agent for the printer IP from `agent_heartbeat`, 3) all other discovered agents; Firestore queue only if all direct HTTP fails, and the app's Firestore enqueue path is currently stubbed to false (`print_job_service.dart:14-52`), i.e. **delivery guarantee today = at-least-once via direct HTTP retries across agents; queue durability exists only agent-side**.
- Kitchen sends run as background tasks with a global progress banner (`kitchen_send_queue.dart:44-50`; persistFn = Firestore write, printFn = agent dispatch, errors surfaced per task).

---

## 8. Odoo touchpoints

- **Custom Odoo REST addon** (not stock Odoo API): full endpoint catalog in `lib/core/constants/api_constants.dart` (`/api/auth/login|logout|verify-credentials`, `/api/pos/products|categories|products-with-modifiers|calculate-with-modifiers|display-categories|deleted-lines|session/adjustment`, `/api/sale/order/create`, `/api/sale/orders`, `/api/payment/methods`, `/api/account/journals/read`, `/api/expense/create`, `/api/warehouse/*`, `/api/dashboard/sales`, ...). Client: `lib/services/odoo_api_service.dart` (3565 lines, Dio; also raw `/web/dataset/call_kw` at `:804,871,898`).
- Server address comes from Firestore `odoo_connections` (url + database), i.e. Firebase bootstraps the Odoo connection.
- Token model (`docs/ODOO_TOKEN_AND_PAYMENT_NAMES.md`): login once → bearer token + expiry stored in SharedPreferences (`odoo_api_service.dart:607`); expiry checked only at app start (`:235`); one mid-run INVALID_TOKEN handler (`:2487`); otherwise silent stale-cache fallbacks. Payment-name resolution merges 4 sources with cache overriding live Odoo (documented defect, `:151-161`).
- Payment names doc also maps journal_id→name resolution order: odooMethods → firebaseMethods(`payment_methods`) → local `journal_names` cache → `session_adjustments`.
- Second Odoo path: `pos_backend` JSON-RPC (section 6), separate credentials, writes `pos.order` directly.
- Note vs offlinePOS repo: Dishflow pushes **sale orders via a custom addon endpoint** (`/api/sale/order/create`), while `/home/username/workspace/offlinePOS` books into jouma as a `sale.order` cascade with an append-only outbox; architecturally similar "till owns data, Odoo is sync destination" but Dishflow's hub is Firestore, offlinePOS's is local.

---

## 9. Multi-tenant / branch model

- **Tenant isolation = one Firebase project per branch/site** (`docs/STATE.md:20,39`); a "client" bundle is produced per tenant by config injection at build time (`deploy_all.ps1`). Same codebase, 13+ deployments to per-tenant cPanel subdomains + optionally Firebase Hosting for the ETA proxy.
- Within a project: `odooConnectionId` scopes every sales query (multiple Odoo connections per project theoretically supported; `loadOdooConnection` picks the single `isActive` one, `firebase_permission_service.dart:493-505`); `branchId` sub-scopes multi-branch tenants. Rules do NOT enforce this scoping (`firestore.rules:41-44` explicitly says isolation moved to code because rule `get()` calls were slow).
- **RM (Reports Manager) multi-tenant mode** (`docs/rm_multi_tenant_plan.md`): named Firebase apps per project (`Firebase.initializeApp(name: 'rm_<projectId>')`), manager's accessible projects listed in `pos_users.rm_accessible_projects`, switcher in the RM shell; production-safe web switching keyed off `reports.code-solution.org` host (`lib/main.dart:154-170`). Companion apps: `rm_mobile_app/` (standalone Flutter RM app with its own firebase.json) and `admin_dashboard _test/`.

---

## 10. Failure modes / single points of failure

- **Internet loss (till side)**: selling continues (local-first orders, Firestore cache, LAN printing via 127.0.0.1/LAN agents). Lost: cross-device realtime (kitchen display, other tills' views, force-logout), menu/ecommerce order intake, Odoo sync, email/WhatsApp reports, ETA submission, Firestore print queue fallback. First-ever launch offline cannot obtain anonymous identity (future rules would deny it, `firebase_identity_service.dart:59-65`).
- **Firestore/Firebase outage**: the whole cross-device layer stops (sales backup, dashboards, suspended-order sharing, agent discovery heartbeats, session close fan-out); till keeps local queue and direct-HTTP printing. Firestore is the de-facto SPOF for coordination.
- **Odoo down**: no impact on selling; orders accumulate as `syncedToOdoo:false`; session close to Odoo blocks/retries (recovery-by-clientOrderRef exists for timeouts, `odoo_api_service.dart:2228`). Token expiry mid-session causes silent stale caches (payment names) rather than hard failure.
- **Print agent host down**: fallback chain localhost → mesh agents → (agent-side) Firestore queue; if the 1-2 POSPrint machines are off, printing dies (mitigated by multi-agent mesh + heartbeats). Job expiry (10 min) prevents post-outage flood printing.
- **Data-loss guards**: pending sales duplicated locally AND in Firestore before Odoo; counter recovery from Firestore max; tombstones prevent deleted-order resurrection; IndexedDB + persistent-storage request against browser eviction; deterministic session ids prevent split sessions from clock/timezone skew.
- **Systemic risks (from SECURITY_REVIEW.md + code)**: world-open Firestore means any tenant's entire operational data is publicly readable/writable today; the derived stats/counters are client-computed (no server authority); no server-side validation of sales writes; two tills updating the same `sales` doc last-write-wins; `sendEmail` relay abuse can burn the SMTP reputation the reports depend on; agent auto-update is an unsigned RCE channel across all sites.

