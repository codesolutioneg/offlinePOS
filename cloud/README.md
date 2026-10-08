# Offline POS cloud server

Two things for a shop, on one server:

- **Backups.** The encrypted whole-till backups the tills upload (Settings →
  Server → Cloud backup). A backup is sealed on the till under the shop's
  recovery key (AES-256-GCM) before it leaves; this server stores the bytes and
  never sees the key, so neither it nor a copy of its disk can open them.
- **The reports site.** Every till also sends its sales, shifts, clock-ins and
  audit trail as they change (`POST /v1/sync`), readable here. The owner and the
  accounts they make sign in to a web build of the till's own reports screen
  (`lib/web_reports/` in the app), so the figures and the layouts are the
  till's. What each account sees is set by its role, its branches and its
  capabilities.

## Run

```sh
cp .env.example .env        # fill POSTGRES_PASSWORD and ADMIN_TOKEN (openssl rand -hex 32)
mkdir -p web                # the reports site goes here (see below)
docker compose up -d --build
curl http://127.0.0.1:4555/health
```

Migrations run on every start (`prisma migrate deploy`). Backups live in the
`posbackup_backups` volume, the database in `posbackup_db`.

The site is the app's web build, mounted read-only from `./web`:

```sh
flutter build web -t lib/web_reports/main.dart --release   # in the app
# copy build/web/* to the server's cloud/web/; no restart needed
```

Put it behind HTTPS. With Caddy, one name for the tills and one for people (both
reach the same process):

```
posbackup.example.com {
	request_body {
		max_size 1100MB
	}
	reverse_proxy 127.0.0.1:4555
}
reports.example.com {
	encode gzip
	reverse_proxy 127.0.0.1:4555
}
```

## Shops, branches, owners

```sh
docker compose exec api node dist/scripts/create-shop.js "Shop name" "First branch" owner
docker compose exec api node dist/scripts/list-shops.js
```

`create-shop` prints the first branch's pairing code and the owner's password,
once each. Every till of a branch pairs with that branch's code. The owner signs
in to the site, adds the other branches (each with its own code), makes a new
code when one has leaked (paired tills stay paired), and makes the other
accounts.

The first backup a shop uploads fixes its recovery key. A till joining later is
told so when it pairs and has to be given the same key; an upload under any other
key is refused (409).

## Accounts

| Role | Branches | Can manage |
| --- | --- | --- |
| owner | all | branches, pairing codes, accounts |
| manager | the ones given, or all | nothing |
| accountant | the ones given, or all | nothing |

Every account reads the sales and shifts of its branches. On top of that it may
hold capabilities: `costs` (margins), `audit` (voids, cancellations, the audit
trail), `staff` (hours), `expenses`, `backoffice` (the back-office layouts) and
`flash`. The owner holds them all. The server only returns the rows an account
may read; the site hides the reports it cannot open.

Passwords are scrypt; a session is an httpOnly cookie for 30 days, sliding.
Five wrong passwords for a username, or thirty from an address, wait fifteen
minutes. A changed password or a disabled account ends its other sessions.

## API

Tills (`Authorization: Bearer <device token>`):

| Method | Path | |
| --- | --- | --- |
| POST | `/v1/devices/pair` | no auth; `{pair_code, device_id, device_name, app_version}` → `{token, shop:{id, name, key_id}, branch:{id, name}}` |
| GET | `/v1/me` | the device's shop and branch |
| POST | `/v1/sync` | `{records:[{kind, key, at, payload}]}`, at most 500; idempotent → `{stored}` |
| POST | `/v1/backups` | raw body (`application/octet-stream`), headers `X-Backup-Sha256`, `X-Backup-Created-At`, `X-Backup-Reason`, `X-Backup-Key-Id` → `{id}` |
| GET | `/v1/backups` | every backup of the device's shop, newest first |
| GET | `/v1/backups/:id` | the sealed bytes |

Record kinds: `order`, `shift`, `attendance`, `audit` (keyed per row), and
`categories`, `costs`, `staff`, `tenders`, `drivers`, `shop` (one per branch).

Admin (`X-Admin-Token`):

| Method | Path | |
| --- | --- | --- |
| POST | `/v1/admin/shops` | `{name, branch?, owner?}` → `{id, name, branch:{id, name, pair_code}, owner:{username, password}\|null}` |
| GET | `/v1/admin/shops` | shops with branch, device, user and backup counts |
| POST | `/v1/admin/shops/:id/branches` | `{name}` → `{id, name, pair_code}` |
| POST | `/v1/admin/branches/:id/pair-code` | new pairing code |

The site (session cookie; a write from another origin is refused):

| Method | Path | |
| --- | --- | --- |
| POST | `/api/auth/login` | `{username, password}` |
| POST | `/api/auth/logout` | |
| GET | `/api/me` | the account, the shop, the branches it sees |
| POST | `/api/me/password` | `{current, next}` |
| GET | `/api/branches` | branches with their tills (last seen, last sync, last backup) |
| POST, PATCH | `/api/branches`, `/api/branches/:id` | owner: add, rename |
| POST | `/api/branches/:id/pair-code` | owner: new pairing code |
| GET | `/api/records?kinds=&branch=all\|<id>&from=&to=` | the rows the account may read |
| GET, POST | `/api/users` | owner: list, add (a password is made when none is given) |
| PATCH, DELETE | `/api/users/:id` | owner: change, remove (never the last active owner) |
| POST | `/api/users/:id/reset-password` | owner: a new password, shown once |

Errors are `{error: "…"}`; the till and the site show the text as it is.
Tokens, pairing codes and session ids are stored as sha256 only.

## Retention

Per till, applied after every upload: everything from the last 48 hours, then the
newest of each day for 30 days, of each month for a year, and of each year after
that. The newest backup a till made is never deleted. An unchanged till uploads
nothing, so an idle shop does not fill the disk.

## Tests

```sh
npm install
npm test          # API, site and sync against an in-memory repository, retention
npm run typecheck
npx tsx scripts/dev-memory.ts ../build/web   # the whole thing on one machine
```
