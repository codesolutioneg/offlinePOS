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
- Certificate pinning on the API.
- Verify the package signature at runtime.

The real moat is the server, the data and the integrations, not the APK.

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

- SQLite encrypted with SQLCipher. The key lives in the platform keystore.
  **Not done yet:** the build depends on plain `sqlite3`, so `Db.open`'s
  `encryptionKey` is accepted and has no effect. Treat every till as carrying its
  sales and staff records in the clear until this is real.
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

## Before go-live

- [x] No secret, key or credential in the repo or the binary
      (the provisioning PIN is random per device and never stored; the release
      public key is a public key)
- [ ] Backend rules deny by default and are tenant-scoped
- [x] PINs Argon2id, attempt limit enforced, persisted across restarts, escalating
- [ ] **Local database encrypted — open blocker.** Needs a SQLCipher-enabled
      `sqlite3` build and a keystore-backed key. See docs/ARCHITECTURE.md.
- [ ] Dependency audit clean of High and Critical
- [x] Signed updates: Ed25519 over the manifest bytes, release key in the build,
      certificate-pinned transport, digest re-checked against the file on disk at
      the moment of install
- [ ] Agents authenticated and loopback-bound
- [ ] Secrets rotated if any ever reached git history
