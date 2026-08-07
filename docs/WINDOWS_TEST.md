# Running offlinePOS on Windows for a local test

A single-operator test on your own PC. It exercises the whole chain: sell, take
payment, print (or spool), and sync to an Odoo build you point it at.

Because it is your own machine, entering an Odoo login in the app is fine. That is
**not** how a real fleet works — many tills must never each hold the one shared Odoo
password, which is why production points at a backend instead. The Server Settings
screen says this on the screen.

## One-time setup

1. Install Flutter for Windows and the desktop toolchain:
   - Flutter SDK (stable), added to PATH
   - Visual Studio with the **"Desktop development with C++"** workload
   - Confirm: `flutter doctor` shows **Visual Studio** and **Windows** with a tick
2. Clone and fetch:
   ```
   git clone git@github.com:codesolutioneg/offlinePOS.git
   cd offlinePOS
   flutter pub get
   ```

## Run it

```
flutter run -d windows
```

The first launch:
- creates its local database next to the app's support dir (nothing in the cloud),
- generates this device's own id,
- seeds one cashier and shows a **random provisioning PIN once** on the sign-in
  screen — note it, that is how you sign in.

## Point it at Odoo

Two ways. Either works; a value typed in the app wins over a build-time default.

**In the app (simplest):** sign in, then the **gear icon** (top-right of the selling
screen) → fill URL, database, login, password → Save. Queued sales sync on the next
attempt, no restart.

**At build time (for a repeatable test):**
```
flutter run -d windows ^
  --dart-define=ODOO_URL=https://<your-build>.dev.odoo.com ^
  --dart-define=ODOO_DB=<database-name> ^
  --dart-define=ODOO_LOGIN=<login> ^
  --dart-define=ODOO_PASSWORD=<password>
```
(`^` is the Windows line-continuation; or put it all on one line.)

The Odoo side must have the `pos_offline_sync` module installed and a Point of Sale
whose **Offline till id** matches — set that on the POS config in Odoo. Sales are
booked into one open "rescue" session per till, each keeping its real date; you close
that session from Odoo when ready.

## Try the offline story

1. Sign in, add products, take payment — a receipt prints if a LAN printer is set on
   the Support screen, otherwise it is spooled and reprintable.
2. **Pull the network** (turn off wifi / unplug). Keep selling. Orders queue.
3. Watch the **Support screen** (life-ring icon): *Sales waiting* climbs, *Oldest
   waiting* shows how long you have been offline.
4. **Reconnect.** Within the sync interval, *Sales waiting* drains to zero and the
   orders appear in Odoo under the rescue session, each with its original time.
5. **Close the app while offline with sales queued, reopen:** the queue is still
   there. Nothing is lost.

## What to expect / known limits for this test

- **No encryption at rest yet.** The local database (sales, PIN hashes) is not
  encrypted; `sqlite3` here is the plain build. Fine for a local test, a blocker for
  a customer. See docs/SECURITY.md.
- **Printing** needs a network (ESC/POS, port 9100) printer on your LAN; without one,
  receipts spool and you can reprint from Support. USB printers are not wired yet.
- **The rescue session** opens in Odoo's "opening control" state; open/close it from
  the Odoo POS UI. Per-day sales reports are correct from the order dates; the
  accounting close is one entry you make when ready.
- Updates and printer discovery are built but a local test does not need them.
