import { createHash, randomBytes } from 'node:crypto';
import { mkdtempSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import type { FastifyInstance } from 'fastify';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';

import { buildApp } from '../src/app.js';
import { MemoryRepo } from '../src/repo.js';
import { Storage } from '../src/storage.js';

const ADMIN = 'admin-secret';
const sha = (b: Buffer) => createHash('sha256').update(b).digest('hex');

let dir: string;
let repo: MemoryRepo;
let app: FastifyInstance;
let clock: Date;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'backup-server-'));
  repo = new MemoryRepo();
  clock = new Date('2026-10-08T12:00:00Z');
  app = buildApp({
    repo,
    storage: new Storage(dir),
    adminToken: ADMIN,
    maxBackupBytes: 1024 * 1024,
    now: () => clock,
  });
});

afterEach(async () => {
  await app.close();
  rmSync(dir, { recursive: true, force: true });
});

async function createShop(name = 'Cairo branch') {
  const res = await app.inject({
    method: 'POST',
    url: '/v1/admin/shops',
    headers: { 'x-admin-token': ADMIN },
    payload: { name },
  });
  expect(res.statusCode).toBe(201);
  return res.json() as { id: string; name: string; pair_code: string };
}

async function pair(code: string, deviceId = 'till-1') {
  const res = await app.inject({
    method: 'POST',
    url: '/v1/devices/pair',
    payload: { pair_code: code, device_id: deviceId, device_name: `Till ${deviceId}`, app_version: '1.0' },
  });
  return res;
}

function upload(
  token: string,
  body: Buffer,
  opts: { keyId?: string; sha?: string; createdAt?: string; reason?: string } = {},
) {
  return app.inject({
    method: 'POST',
    url: '/v1/backups',
    headers: {
      authorization: `Bearer ${token}`,
      'content-type': 'application/octet-stream',
      'x-backup-sha256': opts.sha ?? sha(body),
      'x-backup-key-id': opts.keyId ?? 'key-a',
      'x-backup-created-at': opts.createdAt ?? clock.toISOString(),
      'x-backup-reason': opts.reason ?? 'hourly',
    },
    payload: body,
  });
}

async function pairedTill(deviceId = 'till-1') {
  const shop = await createShop();
  const res = await pair(shop.pair_code, deviceId);
  return { shop, token: res.json().token as string };
}

describe('admin', () => {
  it('refuses without the admin token', async () => {
    const res = await app.inject({ method: 'POST', url: '/v1/admin/shops', payload: { name: 'x' } });
    expect(res.statusCode).toBe(401);
    const wrong = await app.inject({
      method: 'GET',
      url: '/v1/admin/shops',
      headers: { 'x-admin-token': 'nope' },
    });
    expect(wrong.statusCode).toBe(401);
  });

  it('is switched off when no admin token is configured', async () => {
    const closed = buildApp({ repo, storage: new Storage(dir), adminToken: '', maxBackupBytes: 1 });
    const res = await closed.inject({
      method: 'GET',
      url: '/v1/admin/shops',
      headers: { 'x-admin-token': '' },
    });
    expect(res.statusCode).toBe(401);
    await closed.close();
  });

  it('makes a shop with a pairing code that is not stored as typed', async () => {
    const shop = await createShop();
    expect(shop.pair_code).toMatch(/^[0-9A-Z]{4}-[0-9A-Z]{4}-[0-9A-Z]{4}-[0-9A-Z]{4}$/);
    expect(JSON.stringify(repo.shops)).not.toContain(shop.pair_code);
  });

  it('a new pairing code retires the old one', async () => {
    const shop = await createShop();
    const res = await app.inject({
      method: 'POST',
      url: `/v1/admin/shops/${shop.id}/pair-code`,
      headers: { 'x-admin-token': ADMIN },
    });
    const fresh = res.json().pair_code as string;
    expect((await pair(shop.pair_code)).statusCode).toBe(404);
    expect((await pair(fresh)).statusCode).toBe(200);
  });
});

describe('pairing', () => {
  it('trades the code for a token, however the code was typed', async () => {
    const shop = await createShop();
    const sloppy = shop.pair_code.toLowerCase().replace(/-/g, ' ');
    const res = await pair(sloppy);
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.token).toHaveLength(43);
    expect(body.shop).toEqual({ id: shop.id, name: 'Cairo branch', key_id: null });
    expect(JSON.stringify(repo.devices)).not.toContain(body.token);
  });

  it('refuses an unknown code', async () => {
    await createShop();
    const res = await pair('AAAA-BBBB-CCCC-DDDD');
    expect(res.statusCode).toBe(404);
    expect(res.json().error).toBe('unknown pairing code');
  });

  it('pairing the same till again replaces its token', async () => {
    const shop = await createShop();
    const first = (await pair(shop.pair_code)).json().token;
    const second = (await pair(shop.pair_code)).json().token;
    expect(repo.devices).toHaveLength(1);
    const me = (t: string) =>
      app.inject({ method: 'GET', url: '/v1/me', headers: { authorization: `Bearer ${t}` } });
    expect((await me(first)).statusCode).toBe(401);
    expect((await me(second)).json().shop.name).toBe('Cairo branch');
  });
});

describe('backups', () => {
  it('takes a backup, lists it, and gives back the same bytes', async () => {
    const { token } = await pairedTill();
    const body = randomBytes(50_000);
    const up = await upload(token, body, { reason: 'shift-close' });
    expect(up.statusCode).toBe(201);
    const id = up.json().id;

    const list = await app.inject({
      method: 'GET',
      url: '/v1/backups',
      headers: { authorization: `Bearer ${token}` },
    });
    expect(list.json().backups).toEqual([
      expect.objectContaining({
        id,
        device_id: 'till-1',
        device_name: 'Till till-1',
        size: 50_000,
        reason: 'shift-close',
        key_id: 'key-a',
        created_at: clock.toISOString(),
      }),
    ]);

    const down = await app.inject({
      method: 'GET',
      url: `/v1/backups/${id}`,
      headers: { authorization: `Bearer ${token}` },
    });
    expect(down.statusCode).toBe(200);
    expect(down.rawPayload.equals(body)).toBe(true);
    expect(down.headers['x-backup-sha256']).toBe(sha(body));
  });

  it('needs a paired device', async () => {
    const res = await upload('not-a-token', randomBytes(10));
    expect(res.statusCode).toBe(401);
  });

  it('refuses a body that does not match its checksum, and keeps nothing', async () => {
    const { token } = await pairedTill();
    const res = await upload(token, randomBytes(100), { sha: sha(randomBytes(100)) });
    expect(res.statusCode).toBe(400);
    expect(repo.backups).toHaveLength(0);
    expect(readdirSync(join(dir, '.incoming'))).toHaveLength(0);
  });

  it('refuses one over the size limit', async () => {
    const { token } = await pairedTill();
    const res = await upload(token, randomBytes(1024 * 1024 + 1));
    expect(res.statusCode).toBe(413);
    expect(repo.backups).toHaveLength(0);
  });

  it('the same bytes twice are stored once', async () => {
    const { token } = await pairedTill();
    const body = randomBytes(1000);
    const a = await upload(token, body);
    const b = await upload(token, body);
    expect(b.statusCode).toBe(200);
    expect(b.json()).toEqual({ id: a.json().id, duplicate: true });
    expect(repo.backups).toHaveLength(1);
  });

  it('the first backup fixes the shop\'s recovery key; another is refused', async () => {
    const { shop, token } = await pairedTill();
    expect((await upload(token, randomBytes(10), { keyId: 'key-a' })).statusCode).toBe(201);
    const other = await upload(token, randomBytes(10), { keyId: 'key-b' });
    expect(other.statusCode).toBe(409);
    expect(other.json().error).toBe('this shop uses a different recovery key');

    // And a till joining later is told which key it has to bring.
    const joined = await pair(shop.pair_code, 'till-2');
    expect(joined.json().shop.key_id).toBe('key-a');
  });

  it('one shop cannot see or fetch another\'s backups', async () => {
    const a = await pairedTill('till-a');
    const b = await pairedTill('till-b');
    const id = (await upload(a.token, randomBytes(100))).json().id;

    const list = await app.inject({
      method: 'GET',
      url: '/v1/backups',
      headers: { authorization: `Bearer ${b.token}` },
    });
    expect(list.json().backups).toEqual([]);
    const fetch = await app.inject({
      method: 'GET',
      url: `/v1/backups/${id}`,
      headers: { authorization: `Bearer ${b.token}` },
    });
    expect(fetch.statusCode).toBe(404);
  });

  it('every till of a shop sees every backup of the shop', async () => {
    const shop = await createShop();
    const t1 = (await pair(shop.pair_code, 'till-1')).json().token;
    const t2 = (await pair(shop.pair_code, 'till-2')).json().token;
    await upload(t1, randomBytes(10));
    await upload(t2, randomBytes(10));
    const list = await app.inject({
      method: 'GET',
      url: '/v1/backups',
      headers: { authorization: `Bearer ${t2}` },
    });
    expect(list.json().backups.map((b: { device_id: string }) => b.device_id).sort()).toEqual([
      'till-1',
      'till-2',
    ]);
  });

  it('old backups are thinned as new ones arrive, files included', async () => {
    const { token } = await pairedTill();
    const day = 24 * 60 * 60 * 1000;
    // Four backups on the same day five days ago, then one now.
    for (let h = 0; h < 4; h++) {
      const at = new Date(clock.getTime() - 5 * day + h * 3600_000).toISOString();
      await upload(token, randomBytes(10), { createdAt: at });
    }
    await upload(token, randomBytes(10));
    expect(repo.backups).toHaveLength(2);
    const shopDir = readdirSync(dir).find((d) => d !== '.incoming')!;
    expect(readdirSync(join(dir, shopDir))).toHaveLength(2);
  });
});
