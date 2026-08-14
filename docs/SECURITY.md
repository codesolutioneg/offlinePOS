# Security rules

These are hard rules, not preferences. Each one exists because the pattern it forbids
is live in a POS codebase we already own, and was found in review.

## Assume the binary is public

Anything shipped to a device can be extracted. Flutter compiles Dart to native code,
which raises the cost, but `reFlutter` and `Blutter` recover class and method
metadata from AOT snapshots. Design so that having the binary gains an attacker
nothing.

- **No secrets in the app.** No API keys, no tokens, no database credentials, no
  shared encryption key. Anything in the binary is public.
- Build with `--obfuscate --split-debug-info=<dir>`, and keep the debug-info output
  or crashes cannot be symbolicated.
- **Certificate pinning on the API. Implemented** (see below).
- Verify the package signature at runtime.

The real moat is the server, the data and the integrations, not the APK.

### Pinning on the sync transport

Every Odoo call goes through a pinned transport when the build carries pins
(`SYNC_CERT_PINS`), the same way the update channel does. What is pinned is the
**sha256 of the DER leaf certificate**, checked **during the TLS handshake, before the
request body is written**, because that body is the secret: the shared integration login
on authenticate, and the day's takings on a close. Checking the certificate that came back
with the response would mean refusing the reply after already handing the login to whoever
answered.

Two consequences worth stating plainly:

- Pinning **replaces** chain validation rather than adding to it. The client trusts no
  roots, so a CA an operator installed on the device cannot mint a certificate this till
  will talk to. The cost is that an expired pinned certificate is still accepted, so a
  **rotation has to be staged with two pins**: ship the new pin, then swap the
  certificate.
- **No pins configured means today's platform trust store**, which is what every till
  already installed runs on. This one cannot be all-or-nothing like the update channel: a
  pin invented for a shop that was never given one is a till that can never reach its own
  server, and a till that cannot sync is a shop that cannot bank its day. A build that
  ships pins is still the rule.

A certificate that does not match throws, and the sender treats anything thrown here as
transient, so a queued sale is kept and retried rather than parked as if the server had
refused the money.

## The shop LAN is an authentication boundary, not a private channel

The devices in one shop share state directly with each other (docs/LAN_SYNC.md). What
that trust is worth, stated honestly:

- **Peers are authenticated, by a shared shop key.** Every request carries an HMAC-SHA256
  stamp over its method, path, canonical query, timestamp and body. The key never goes on
  the wire, so a device listening on the switch learns nothing it can reuse, and the stamp
  cannot be lifted off one request and replayed on another shape of request. A refusal is
  a `401` naming the reason (no key, another shop's key, a clock too far out) and is
  recorded in the audit trail.
- **The traffic is not encrypted.** Events are plain JSON over plain HTTP. Anything that
  can capture traffic on the shop switch can read a page it caught. Pairing keeps
  strangers from *asking*; it does not keep them from *listening*.
- **A device holding the key is trusted fully.** It can read the open tabs and push
  orders, tickets and floor changes into every till in the shop. The one thing it cannot
  do is make another till book a sale: applying a peer's events has no path to the outbox,
  and the reads that decide money are scoped to the device that rang them. Treat the shop
  key as the shop's key: whoever has it is a till.
- **The key lives in the encrypted settings store**, generated on the device the first
  time sharing is switched on, never in the binary and never in a build define. Rotating
  it from the shop network screen unpairs every other device until each is given the new
  one.
- The fabric binds to the device's LAN address, not to every interface, and opens no
  socket at all when sharing is off.

## Cryptography

- **Never hand-roll a cipher.** Use AES-GCM from a maintained library. An unauthenticated
  stream construction is malleable: an attacker can flip bits in the ciphertext.
- **Never encrypt with a hardcoded app-wide key.** One extraction compromises every
  installation at every client, forever.
- Keys come from the platform keystore, or are derived per-device from a
  server-issued secret. Never from a constant in source.

## PINs

- Hash with **Argon2id**, tuned so a single verification takes ~100 ms on the target
  device.
- A fast hash is not acceptable. A 4-6 digit PIN is 10⁴–10⁶ candidates; against
  `SHA-256(salt + pin)` that is exhausted in milliseconds once the device is in hand.
- **Enforce an attempt limit** with escalating backoff. "No lockout" is not a product
  decision anyone gets to make on a payment terminal.

## Data at rest

- SQLite encrypted with SQLCipher, key generated once per device and held in the
  platform keychain, never beside the data. Done and proven: the file holds no clear
  text and a wrong key is rejected rather than quietly reading nothing.
- Never store sales, customers or staff records in plain `SharedPreferences`. A lost
  or stolen till must not leak them.
- Support remote wipe of a device's local data.

## Backend authorisation

- Every rule is enforced **server-side**. The client is untrusted input.
- Multi-tenant data must be scoped by tenant in the security rules themselves, not by
  the client sending the right filter. A catch-all
  `allow read, write: if true` makes the whole database world-readable to anyone who
  learns the project id, with no reverse engineering required.
- Cloud functions authenticate their caller. An unauthenticated callable that sends
  mail is an open relay.

## Licensing must never block a sale

Cache a signed, time-boxed licence token with a grace period longer than the worst
realistic outage. Renew silently when online. If the licence check needs the network
to authorise a transaction, the app has recreated the outage problem it exists to
solve.

## Auxiliary agents

Print agents, fingerprint agents and similar helpers are part of the attack surface:

- Bind to loopback, not to every interface.
- Authenticate their control endpoints.
- **Auto-update must verify a signature.** An unsigned auto-updating agent is remote
  code execution on every till.

The shop fabric is the one deliberate exception to the loopback rule: the other devices
have to reach it. It binds to the LAN address rather than to every interface, and every
request is authenticated, which is the same bargain with the second rule kept.

## Before go-live

- [x] No secret, key or credential in the repo or the binary
      (the provisioning PIN is random per device and never stored; the release
      public key is a public key)
- [ ] Backend rules deny by default and are tenant-scoped
- [x] PINs Argon2id, attempt limit enforced, persisted across restarts, escalating
- [x] **Local database encrypted** with SQLCipher; key generated once and held in
      the platform keychain (flutter_secure_storage), never beside the data.
      Proven: data is not in the file as clear text and a wrong key is rejected.
- [ ] Dependency audit clean of High and Critical
- [x] Signed updates: Ed25519 over the manifest bytes, release key in the build,
      certificate-pinned transport, digest re-checked against the file on disk at
      the moment of install
- [x] **Sync transport pinned** when the build carries pins: leaf digest checked in the
      handshake before the login or the takings are written. No pins means the platform
      trust store, and rotation needs two pins
- [x] **Shop LAN peers authenticated** by a shared key, per-request HMAC, key never on
      the wire and never in the binary. The traffic itself is not encrypted, so a paired
      device is a trusted device
- [ ] Agents authenticated and loopback-bound
- [ ] Per-device identity: the enrolment token is written and tested but unwired, and the
      till still authenticates as the shared integration login. **Open on purpose:** it
      needs a server endpoint to issue and revoke tokens, and no new server endpoint is
      being built (docs/ODOO_SYNC.md)
- [ ] Secrets rotated if any ever reached git history. Also open on purpose for the sync
      credential: it is one shared server login, so rotating it is an Odoo-side change
      plus a config redeploy, not something the till can do to itself
