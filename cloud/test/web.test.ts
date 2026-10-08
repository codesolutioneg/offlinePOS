import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import type { FastifyInstance, LightMyRequestResponse } from 'fastify';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';

import { buildApp, MAX_SYNC_RECORDS } from '../src/app.js';
import { MemoryRepo } from '../src/repo.js';
import { Storage } from '../src/storage.js';
import { SESSION_COOKIE } from '../src/web.js';

const ADMIN = 'admin-secret';

let dir: string;
let repo: MemoryRepo;
let app: FastifyInstance;
let clock: Date;

beforeEach(async () => {
  dir = mkdtempSync(join(tmpdir(), 'reports-server-'));
  repo = new MemoryRepo();
  clock = new Date('2026-10-08T12:00:00Z');
  const web = join(dir, 'web');
  mkdirSync(web);
  writeFileSync(join(web, 'index.html'), '<html>reports</html>');
  writeFileSync(join(web, 'main.dart.js'), 'console.log(1)');
  app = await buildApp({
    repo,
    storage: new Storage(join(dir, 'backups')),
    adminToken: ADMIN,
    maxBackupBytes: 1024 * 1024,
    now: () => clock,
    webDir: web,
  });
});

afterEach(async () => {
  await app.close();
  rmSync(dir, { recursive: true, force: true });
});

interface Shop {
  id: string;
  branch: { id: string; pair_code: string };
  owner: { username: string; password: string };
}

async function createShop(owner = 'owner1', name = 'Koshary'): Promise<Shop> {
  const res = await app.inject({
    method: 'POST',
    url: '/v1/admin/shops',
    headers: { 'x-admin-token': ADMIN },
    payload: { name, branch: 'Dokki', owner },
  });
  expect(res.statusCode).toBe(201);
  return res.json();
}

const cookieOf = (res: LightMyRequestResponse) => {
  const c = res.cookies.find((x) => x.name === SESSION_COOKIE);
  return c ? `${SESSION_COOKIE}=${c.value}` : '';
};

async function login(username: string, password: string) {
  return app.inject({ method: 'POST', url: '/api/auth/login', payload: { username, password } });
}

async function session(username: string, password: string) {
  const res = await login(username, password);
  expect(res.statusCode).toBe(200);
  return cookieOf(res);
}

const get = (url: string, cookie: string) => app.inject({ method: 'GET', url, headers: { cookie } });
const send = (method: 'POST' | 'PATCH' | 'DELETE', url: string, cookie: string, payload?: object) =>
  app.inject({ method, url, headers: { cookie }, payload });

async function till(code: string, deviceId: string) {
  const res = await app.inject({
    method: 'POST',
    url: '/v1/devices/pair',
    payload: { pair_code: code, device_id: deviceId, device_name: deviceId, app_version: '1' },
  });
  expect(res.statusCode).toBe(200);
  return res.json().token as string;
}

const sync = (token: string, records: object[]) =>
  app.inject({
    method: 'POST',
    url: '/v1/sync',
    headers: { authorization: `Bearer ${token}` },
    payload: { records },
  });

const order = (uuid: string, at: string, total = 10) => ({
  kind: 'order',
  key: uuid,
  at,
  payload: { uuid, total, created_at: at },
});

describe('signing in', () => {
  it('the owner made with the shop signs in and sees the shop', async () => {
    const shop = await createShop();
    expect(shop.owner.password).toHaveLength(12);
    const cookie = await session('owner1', shop.owner.password);
    const me = await get('/api/me', cookie);
    expect(me.statusCode).toBe(200);
    expect(me.json()).toMatchObject({
      user: { username: 'owner1', role: 'owner', all_branches: true },
      shop: { name: 'Koshary' },
      branches: [{ id: shop.branch.id, name: 'Dokki' }],
    });
    expect(me.json().user.capabilities).toContain('costs');
  });

  it('the session cookie is http-only and the password is stored hashed', async () => {
    const shop = await createShop();
    const res = await login('OWNER1', shop.owner.password);
    const c = res.cookies.find((x) => x.name === SESSION_COOKIE)!;
    expect(c.httpOnly).toBe(true);
    expect(c.sameSite).toBe('Lax');
    expect(JSON.stringify(repo.users)).not.toContain(shop.owner.password);
    expect(JSON.stringify(repo.sessions)).not.toContain(c.value);
  });

  it('refuses a wrong password, and locks the username after five', async () => {
    const shop = await createShop();
    for (let i = 0; i < 5; i++) {
      expect((await login('owner1', 'wrong-password')).statusCode).toBe(401);
    }
    const locked = await login('owner1', shop.owner.password);
    expect(locked.statusCode).toBe(429);
    clock = new Date(clock.getTime() + 16 * 60 * 1000);
    expect((await login('owner1', shop.owner.password)).statusCode).toBe(200);
  });

  it('an unknown username reads the same as a wrong password', async () => {
    await createShop();
    const res = await login('nobody', 'whatever1');
    expect(res.statusCode).toBe(401);
    expect(res.json().error).toBe('wrong username or password');
  });

  it('nothing under /api answers without a session', async () => {
    for (const url of ['/api/me', '/api/branches', '/api/records?kinds=order', '/api/users']) {
      expect((await get(url, '')).statusCode).toBe(401);
    }
  });

  it('a session lapses after thirty days unused, and sign-out ends it at once', async () => {
    const shop = await createShop();
    const cookie = await session('owner1', shop.owner.password);
    await send('POST', '/api/auth/logout', cookie);
    expect((await get('/api/me', cookie)).statusCode).toBe(401);

    const again = await session('owner1', shop.owner.password);
    clock = new Date(clock.getTime() + 31 * 24 * 60 * 60 * 1000);
    expect((await get('/api/me', again)).statusCode).toBe(401);
  });

  it('a change from another site is refused', async () => {
    const shop = await createShop();
    const cookie = await session('owner1', shop.owner.password);
    const res = await app.inject({
      method: 'POST',
      url: '/api/branches',
      headers: { cookie, origin: 'https://evil.example', host: 'reports.test' },
      payload: { name: 'Evil' },
    });
    expect(res.statusCode).toBe(403);
  });

  it('changing the password signs every other browser out', async () => {
    const shop = await createShop();
    const here = await session('owner1', shop.owner.password);
    const there = await session('owner1', shop.owner.password);
    const res = await send('POST', '/api/me/password', here, {
      current: shop.owner.password,
      next: 'a-new-password',
    });
    expect(res.statusCode).toBe(204);
    expect((await get('/api/me', here)).statusCode).toBe(200);
    expect((await get('/api/me', there)).statusCode).toBe(401);
    expect((await login('owner1', 'a-new-password')).statusCode).toBe(200);
  });
});

describe('what a till sends', () => {
  it('is stored once however often it is sent, and the owner reads it back', async () => {
    const shop = await createShop();
    const token = await till(shop.branch.pair_code, 'till-1');
    const batch = [order('o1', '2026-10-08T09:00:00Z'), order('o2', '2026-10-07T09:00:00Z')];
    expect((await sync(token, batch)).json()).toEqual({ stored: 2 });
    await sync(token, [order('o1', '2026-10-08T09:00:00Z', 25)]);

    const cookie = await session('owner1', shop.owner.password);
    const res = await get(
      '/api/records?kinds=order&from=2026-10-08T00:00:00Z&to=2026-10-09T00:00:00Z',
      cookie,
    );
    expect(res.json().records).toEqual([
      {
        kind: 'order',
        key: 'o1',
        branch_id: shop.branch.id,
        at: '2026-10-08T09:00:00.000Z',
        payload: { uuid: 'o1', total: 25, created_at: '2026-10-08T09:00:00Z' },
      },
    ]);
    expect(repo.devices[0].lastSyncAt).toEqual(clock);
  });

  it('a branch snapshot is keyed by the till\'s branch, whatever it claims', async () => {
    const shop = await createShop();
    const token = await till(shop.branch.pair_code, 'till-1');
    await sync(token, [{ kind: 'categories', key: 'someone-elses-branch', at: null, payload: [{ id: 1 }] }]);
    expect(repo.records[0].key).toBe(shop.branch.id);
  });

  it('refuses what it does not understand', async () => {
    const shop = await createShop();
    const token = await till(shop.branch.pair_code, 'till-1');
    expect((await sync(token, [{ kind: 'passwords', key: 'x', at: null, payload: {} }])).statusCode).toBe(400);
    expect((await sync(token, [{ kind: 'order', key: '', at: null, payload: {} }])).statusCode).toBe(400);
    expect((await sync(token, [{ kind: 'order', key: 'a', at: 'not a time', payload: {} }])).statusCode).toBe(400);
    const tooMany = Array.from({ length: MAX_SYNC_RECORDS + 1 }, (_, i) => order(`o${i}`, '2026-10-08T09:00:00Z'));
    expect((await sync(token, tooMany)).statusCode).toBe(413);
    expect((await sync('nope', [])).statusCode).toBe(401);
    expect(repo.records).toHaveLength(0);
  });
});

describe('who sees what', () => {
  let shop: Shop;
  let owner: string;
  let otherBranch: { id: string; pair_code: string };

  beforeEach(async () => {
    shop = await createShop();
    owner = await session('owner1', shop.owner.password);
    otherBranch = (await send('POST', '/api/branches', owner, { name: 'Maadi' })).json();
    const dokki = await till(shop.branch.pair_code, 'till-dokki');
    const maadi = await till(otherBranch.pair_code, 'till-maadi');
    await sync(dokki, [
      order('d1', '2026-10-08T09:00:00Z'),
      { kind: 'costs', key: 'x', at: null, payload: { '1': 2.5 } },
      { kind: 'audit', key: 'till-dokki:1', at: '2026-10-08T09:00:00Z', payload: { event: 'line.voided' } },
      { kind: 'attendance', key: 'sara|2026-10-08T08:00:00Z', at: '2026-10-08T08:00:00Z', payload: {} },
    ]);
    await sync(maadi, [order('m1', '2026-10-08T10:00:00Z')]);
  });

  async function addUser(body: object) {
    const res = await send('POST', '/api/users', owner, body);
    expect(res.statusCode).toBe(201);
    return res.json() as { user: { id: string; capabilities: string[] }; password: string };
  }

  const keys = async (cookie: string, query: string) =>
    (await get(`/api/records?${query}`, cookie)).json().records.map((r: { key: string }) => r.key).sort();

  it('the owner sees every branch', async () => {
    expect(await keys(owner, 'kinds=order')).toEqual(['d1', 'm1']);
    const branches = (await get('/api/branches', owner)).json().branches;
    expect(branches.map((b: { name: string }) => b.name)).toEqual(['Dokki', 'Maadi']);
    expect(branches[0].devices[0]).toMatchObject({ id: 'till-dokki', last_sync_at: clock.toISOString() });
  });

  it('a branch manager sees their branch and nothing of the other', async () => {
    const m = await addUser({ username: 'mgr', role: 'manager', branch_ids: [shop.branch.id] });
    const cookie = await session('mgr', m.password);
    expect(await keys(cookie, 'kinds=order')).toEqual(['d1']);
    expect(await keys(cookie, `kinds=order&branch=${shop.branch.id}`)).toEqual(['d1']);
    expect((await get(`/api/records?kinds=order&branch=${otherBranch.id}`, cookie)).statusCode).toBe(403);
    const me = (await get('/api/me', cookie)).json();
    expect(me.branches.map((b: { name: string }) => b.name)).toEqual(['Dokki']);
    expect((await get('/api/branches', cookie)).json().branches).toHaveLength(1);
  });

  it('an accountant is not sent costs, the audit trail or clock-ins', async () => {
    const a = await addUser({ username: 'acc', role: 'accountant', all_branches: true });
    expect(a.user.capabilities.sort()).toEqual(['backoffice', 'expenses', 'flash']);
    const cookie = await session('acc', a.password);
    expect(await keys(cookie, 'kinds=order,costs,audit,attendance')).toEqual(['d1', 'm1']);
    expect(await keys(owner, 'kinds=costs,audit,attendance')).toEqual([
      shop.branch.id,
      'sara|2026-10-08T08:00:00Z',
      'till-dokki:1',
    ]);
  });

  it('the owner can grant a capability the role lacks', async () => {
    const a = await addUser({ username: 'acc2', role: 'accountant', all_branches: true, capabilities: ['costs'] });
    const cookie = await session('acc2', a.password);
    expect(await keys(cookie, 'kinds=costs')).toEqual([shop.branch.id]);
  });

  it('only the owner manages users and branches', async () => {
    const m = await addUser({ username: 'mgr2', role: 'manager', all_branches: true });
    const cookie = await session('mgr2', m.password);
    expect((await get('/api/users', cookie)).statusCode).toBe(403);
    expect((await send('POST', '/api/users', cookie, { username: 'x1y', role: 'owner' })).statusCode).toBe(403);
    expect((await send('POST', '/api/branches', cookie, { name: 'New' })).statusCode).toBe(403);
    expect((await send('POST', `/api/branches/${shop.branch.id}/pair-code`, cookie)).statusCode).toBe(403);
  });

  it('switching a user off signs them out on the spot', async () => {
    const m = await addUser({ username: 'mgr3', role: 'manager', all_branches: true });
    const cookie = await session('mgr3', m.password);
    const res = await send('PATCH', `/api/users/${m.user.id}`, owner, { active: false });
    expect(res.statusCode).toBe(200);
    expect((await get('/api/me', cookie)).statusCode).toBe(401);
    expect((await login('mgr3', m.password)).statusCode).toBe(401);
  });

  it('a reset password replaces the old one', async () => {
    const m = await addUser({ username: 'mgr4', role: 'manager', all_branches: true });
    const reset = (await send('POST', `/api/users/${m.user.id}/reset-password`, owner)).json();
    expect((await login('mgr4', m.password)).statusCode).toBe(401);
    expect((await login('mgr4', reset.password)).statusCode).toBe(200);
  });

  it('the shop always keeps an active owner', async () => {
    const me = (await get('/api/me', owner)).json().user;
    expect((await send('PATCH', `/api/users/${me.id}`, owner, { role: 'manager' })).statusCode).toBe(400);
    expect((await send('PATCH', `/api/users/${me.id}`, owner, { active: false })).statusCode).toBe(400);
    expect((await send('DELETE', `/api/users/${me.id}`, owner)).statusCode).toBe(400);
    const second = await addUser({ username: 'owner2', role: 'owner' });
    expect((await send('PATCH', `/api/users/${me.id}`, owner, { role: 'manager' })).statusCode).toBe(200);
    expect((await send('DELETE', `/api/users/${second.user.id}`, owner)).statusCode).toBe(403);
  });

  it('usernames are unique and checked', async () => {
    expect((await send('POST', '/api/users', owner, { username: 'owner1' })).statusCode).toBe(409);
    expect((await send('POST', '/api/users', owner, { username: 'a b' })).statusCode).toBe(400);
    expect(
      (await send('POST', '/api/users', owner, { username: 'okname', branch_ids: ['not-mine'] })).statusCode,
    ).toBe(400);
    expect(
      (await send('POST', '/api/users', owner, { username: 'okname', capabilities: ['root'] })).statusCode,
    ).toBe(400);
  });

  it('the owner deletes a branch with its tills, records and backups', async () => {
    const m = await addUser({ username: 'mgr5', role: 'manager', branch_ids: [shop.branch.id, otherBranch.id] });
    const maadi = repo.devices.find((d) => d.branchId === otherBranch.id)!;
    mkdirSync(join(dir, 'backups', 'maadi'), { recursive: true });
    writeFileSync(join(dir, 'backups', 'maadi', 'b1.bin'), 'x');
    await repo.addBackup({
      shopId: shop.id,
      deviceRowId: maadi.id,
      createdAt: clock,
      size: 1,
      sha256: 'a'.repeat(64),
      reason: 'test',
      keyId: 'k',
      path: 'maadi/b1.bin',
    });

    const mgr = await session('mgr5', m.password);
    expect((await send('DELETE', `/api/branches/${otherBranch.id}`, mgr)).statusCode).toBe(403);
    expect((await send('DELETE', `/api/branches/${otherBranch.id}`, owner)).statusCode).toBe(204);

    expect((await get('/api/branches', owner)).json().branches.map((b: { name: string }) => b.name)).toEqual([
      'Dokki',
    ]);
    expect(await keys(owner, 'kinds=order')).toEqual(['d1']);
    expect(repo.devices.map((d) => d.deviceId)).toEqual(['till-dokki']);
    expect(repo.backups).toHaveLength(0);
    expect(existsSync(join(dir, 'backups', 'maadi', 'b1.bin'))).toBe(false);
    expect(repo.users.find((u) => u.username === 'mgr5')!.branchIds).toEqual([shop.branch.id]);
    expect((await send('DELETE', `/api/branches/${otherBranch.id}`, owner)).statusCode).toBe(404);
    // The shop keeps somewhere to pair a till.
    expect((await send('DELETE', `/api/branches/${shop.branch.id}`, owner)).statusCode).toBe(409);
  });

  it('one shop\'s owner cannot touch another shop', async () => {
    const other = await createShop('owner9', 'Other shop');
    const cookie = await session('owner9', other.owner.password);
    expect(await keys(cookie, 'kinds=order')).toEqual([]);
    expect((await get(`/api/records?kinds=order&branch=${shop.branch.id}`, cookie)).statusCode).toBe(403);
    const me = (await get('/api/me', owner)).json().user;
    expect((await send('PATCH', `/api/users/${me.id}`, cookie, { active: false })).statusCode).toBe(404);
    expect((await send('POST', `/api/branches/${shop.branch.id}/pair-code`, cookie)).statusCode).toBe(404);
    expect((await send('DELETE', `/api/branches/${shop.branch.id}`, cookie)).statusCode).toBe(404);
  });
});

describe('the site', () => {
  it('serves the built app, and its routes fall back to it', async () => {
    expect((await app.inject({ method: 'GET', url: '/' })).body).toContain('reports');
    expect((await app.inject({ method: 'GET', url: '/main.dart.js' })).body).toContain('console');
    expect((await app.inject({ method: 'GET', url: '/reports/today' })).body).toContain('reports');
    const api = await app.inject({ method: 'GET', url: '/api/nothing' });
    expect(api.statusCode).toBe(404);
    expect(api.json().error).toBeDefined();
  });
});
