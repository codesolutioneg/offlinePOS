# offlinePOS

An offline-first point of sale. The till owns its data; the server is a destination,
not a dependency.

## Why

The Odoo POS is a web page. Cut the internet and it keeps selling **only while the
tab stays open** — close it, reload it, or reboot the machine and you get
`ERR_INTERNET_DISCONNECTED`, because Odoo persists only orders locally and never the
catalogue. An installed app has the binary and the data already on the device, so a
cold start with no network is just a normal start.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the design and the evidence
behind it, and [`docs/SECURITY.md`](docs/SECURITY.md) for the rules the code must
hold to.

## What is here so far

The offline core, with tests:

| Area | File | Guarantee |
|---|---|---|
| Identity | `lib/domain/identity.dart` | Client-generated UUIDs, so replay is safe |
| Sales model | `lib/domain/order.dart` | Modifier prices captured at sale time |
| Sync | `lib/core/sync/outbox.dart` | Append-only queue, ordered, idempotent, never drops |
| PIN rules | `lib/core/auth/pin_policy.dart` | Attempt limit and lockout |
| Device auth | `lib/core/auth/device_token.dart` | Grace period longer than any realistic outage |

```bash
flutter test      # 17 tests
flutter analyze
```

## Not built yet

Encrypted SQLite store, Argon2id hashing behind `PinPolicy`, the Odoo sync sender,
ESC/POS printing, and the UI. The interfaces they plug into (`OutboxStore`,
`OutboxSender`) are defined and covered by tests against in-memory fakes.

## Conventions

Pushed with the `AhmedOsam` SSH key. The repo pins it locally:

```bash
git config --local core.sshCommand "ssh -i ~/.ssh/id_ed25519_yasser -o IdentitiesOnly=yes"
```
