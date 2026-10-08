# Offline POS backup server

Keeps the encrypted whole-till backups the tills upload (Settings → Server →
Cloud backup). A backup is sealed on the till under the shop's recovery key
(AES-256-GCM) before it leaves; this server stores the bytes and never sees the
key, so neither it nor a copy of its disk can open them.

Phase 1 of the cloud plan: the backups. Row-level sync and web reports come later
and will sit beside this, not replace it.

## Run

```sh
cp .env.example .env        # fill POSTGRES_PASSWORD and ADMIN_TOKEN (openssl rand -hex 32)
docker compose up -d --build
curl http://127.0.0.1:4555/health
```

Migrations run on every start (`prisma migrate deploy`). Backups live in the
`posbackup_backups` volume, the database in `posbackup_db`.

Put it behind HTTPS. With Caddy:

```
posbackup.example.com {
	request_body {
		max_size 1100MB
	}
	reverse_proxy 127.0.0.1:4555
}
```

## Shops and pairing

```sh
docker compose exec api node dist/scripts/create-shop.js "Cairo branch"
docker compose exec api node dist/scripts/list-shops.js
```

`create-shop` prints the shop's pairing code, once. Every till of the shop pairs
with the same code. A new code (the old one stops working; paired tills are not
affected):

```sh
curl -X POST -H "X-Admin-Token: $ADMIN_TOKEN" https://…/v1/admin/shops/<id>/pair-code
```

The first backup a shop uploads fixes its recovery key. A till joining later is
told so when it pairs and has to be given the same key; an upload under any other
key is refused (409).

## API

| Method | Path | Auth | |
| --- | --- | --- | --- |
| GET | `/health` | none | `{ok:true}` when the database answers |
| POST | `/v1/admin/shops` | `X-Admin-Token` | `{name}` → `{id, name, pair_code}` |
| GET | `/v1/admin/shops` | `X-Admin-Token` | shops with device and backup counts |
| POST | `/v1/admin/shops/:id/pair-code` | `X-Admin-Token` | new pairing code |
| POST | `/v1/devices/pair` | none | `{pair_code, device_id, device_name, app_version}` → `{token, shop:{id, name, key_id}}` |
| GET | `/v1/me` | Bearer | the device's shop |
| POST | `/v1/backups` | Bearer | raw body (`application/octet-stream`), headers `X-Backup-Sha256`, `X-Backup-Created-At`, `X-Backup-Reason`, `X-Backup-Key-Id` → `{id}` |
| GET | `/v1/backups` | Bearer | every backup of the device's shop, newest first |
| GET | `/v1/backups/:id` | Bearer | the sealed bytes |

Errors are `{error: "…"}`; the till shows the text as it is. Tokens and pairing
codes are stored as sha256 only.

## Retention

Per till, applied after every upload: everything from the last 48 hours, then the
newest of each day for 30 days, of each month for a year, and of each year after
that. The newest backup a till made is never deleted. An unchanged till uploads
nothing, so an idle shop does not fill the disk.

## Tests

```sh
npm install
npm test          # API against an in-memory repository, and the retention rules
npm run typecheck
```
