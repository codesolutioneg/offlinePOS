# offlinePOS

An offline-first point of sale. The till owns its data; the server is a destination,
not a dependency.

## Why

The Odoo POS is a web page. Cut the internet and it keeps selling **only while the
tab stays open**. Close it, reload it, or reboot the machine and you get
`ERR_INTERNET_DISCONNECTED`, because Odoo persists only orders locally and never the
catalogue. An installed app has the binary and the data already on the device, so a
cold start with no network is just a normal start.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the design and the evidence
behind it, [`docs/SECURITY.md`](docs/SECURITY.md) for the rules the code must hold to,
[`docs/ODOO_SYNC.md`](docs/ODOO_SYNC.md) for what reaches the server, and
[`docs/LAN_SYNC.md`](docs/LAN_SYNC.md) for how the devices in one shop share state.

## What is here so far

A working till, with tests:

| Area | File | Guarantee |
|---|---|---|
| Identity | `lib/domain/identity.dart` | Client-generated UUIDs, so replay is safe |
| Sales model | `lib/domain/order.dart` | Modifier prices captured at sale time |
| Storage | `lib/core/db/database.dart` | SQLCipher, key in the platform keychain, versioned migrations |
| Sync | `lib/core/sync/outbox.dart` | Append-only queue, ordered, idempotent, never drops |
| Odoo sender | `lib/core/sync/odoo_sender.dart` | Books the sale, delivery, invoice and payment chain, idempotent on the uuid |
| PIN rules | `lib/core/auth/` | Argon2id hashing, attempt limit and lockout that survives a restart |
| Printing | `lib/core/printing/` | ESC/POS text to receipt and kitchen stations |
| Shop network | `lib/core/lan/` | Tills and kitchen screens share tabs, tickets and the floor plan over the LAN |

```bash
flutter test
flutter analyze
```

## Not built

Nothing here needs a server endpoint beyond the one call that books an order, and that is
a decision rather than a gap (docs/ODOO_SYNC.md). So the shift and its cash count, the
audit trail and the device heartbeat stay on the till; the roster, till configuration and
customer records are not distributed from the server; and per-device enrolment tokens are
written but unwired.

Also not built, by prior decision: pricelists, coupons, gift cards, loyalty, stock
quantities, and remote order intake (QR menu, ecommerce, delivery platforms).

## Conventions

Pushed with the `AhmedOsam` SSH key. The repo pins it locally:

```bash
git config --local core.sshCommand "ssh -i ~/.ssh/id_ed25519_yasser -o IdentitiesOnly=yes"
```
