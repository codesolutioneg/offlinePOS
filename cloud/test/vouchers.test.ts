import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import type { FastifyInstance } from 'fastify';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';

import { buildApp } from '../src/app.js';
import { MemoryRepo } from '../src/repo.js';
import { Storage } from '../src/storage.js';
import { SESSION_COOKIE } from '../src/web.js';
import type { VoucherAdmin, VoucherOverview } from '../src/voucher_admin.js';

class FakeVouchers implements VoucherAdmin {
  ranges: VoucherOverview['ranges'] = [{ from: 1, to: 10 }];
  discounts: VoucherOverview['discounts'] = [];
  removed = -1;
  branchName = '';
  lastDiscount: { name: string; percent: number } | null = null;

  async overview(): Promise<VoucherOverview> {
    return {
      percent: 15,
      discounts: this.discounts,
      ranges: this.ranges,
      branches: [{ name: 'Main', key: 'branch-key' }],
      rows: [],
    };
  }

  async addDiscount(name: string, percent: number): Promise<void> {
    this.lastDiscount = { name, percent };
    this.discounts = [...this.discounts, { id: 'd1', name, percent }];
  }

  async removeDiscount(index: number): Promise<void> {
    this.discounts = this.discounts.filter((_, i) => i !== index);
  }

  async addRange(from: number, to: number, discountId?: string): Promise<void> {
    this.ranges = [...this.ranges, { from, to, discount_id: discountId }];
  }

  async removeRange(index: number): Promise<void> {
    this.removed = index;
  }

  async setRangeDiscount(index: number, discountId: string | null): Promise<void> {
    const row = this.ranges[index];
    if (row) row.discount_id = discountId;
  }

  async addBranch(name: string): Promise<{ name: string; key: string }> {
    this.branchName = name;
    return { name, key: 'made-key' };
  }
}

describe('voucher page api', () => {
  let dir: string;
  let app: FastifyInstance;
  let fake: FakeVouchers;
  let ownerCookie: string;

  beforeEach(async () => {
    dir = mkdtempSync(join(tmpdir(), 'voucher-api-'));
    const web = join(dir, 'web');
    mkdirSync(web);
    writeFileSync(join(web, 'index.html'), '<html></html>');
    fake = new FakeVouchers();
    app = await buildApp({
      repo: new MemoryRepo(),
      storage: new Storage(join(dir, 'backups')),
      adminToken: 'admin',
      maxBackupBytes: 1024,
      webDir: web,
      vouchers: fake,
    });
    const made = await app.inject({
      method: 'POST',
      url: '/v1/admin/shops',
      headers: { 'x-admin-token': 'admin' },
      payload: { name: 'Shop', branch: 'Main', owner: 'owner1' },
    });
    const owner = made.json().owner as { username: string; password: string };
    const login = await app.inject({
      method: 'POST',
      url: '/api/auth/login',
      payload: { username: owner.username, password: owner.password },
    });
    const cookie = login.cookies.find((c) => c.name === SESSION_COOKIE);
    ownerCookie = `${SESSION_COOKIE}=${cookie?.value}`;
  });

  afterEach(async () => {
    await app.close();
    rmSync(dir, { recursive: true, force: true });
  });

  it('the owner reads and adds voucher numbers', async () => {
    const page = await app.inject({ method: 'GET', url: '/api/vouchers', headers: { cookie: ownerCookie } });
    expect(page.statusCode).toBe(200);
    expect(page.json().percent).toBe(15);
    expect(page.json().branches[0].key).toBe('branch-key');

    const added = await app.inject({
      method: 'POST',
      url: '/api/vouchers/ranges',
      headers: { cookie: ownerCookie },
      payload: { from: 1, to: 30000 },
    });
    expect(added.statusCode).toBe(200);
    expect(fake.ranges).toEqual([
      { from: 1, to: 10 },
      { from: 1, to: 30000 },
    ]);

    const bad = await app.inject({
      method: 'POST',
      url: '/api/vouchers/ranges',
      headers: { cookie: ownerCookie },
      payload: { from: 20, to: 5 },
    });
    expect(bad.statusCode).toBe(400);

    const branch = await app.inject({
      method: 'POST',
      url: '/api/vouchers/branches',
      headers: { cookie: ownerCookie },
      payload: { name: 'Nasr' },
    });
    expect(branch.statusCode).toBe(200);
    expect(branch.json().key).toBe('made-key');
    expect(fake.branchName).toBe('Nasr');

    const discount = await app.inject({
      method: 'POST',
      url: '/api/vouchers/discounts',
      headers: { cookie: ownerCookie },
      payload: { name: 'Staff', percent: 20 },
    });
    expect(discount.statusCode).toBe(200);
    expect(fake.lastDiscount).toEqual({ name: 'Staff', percent: 20 });

    const badDiscount = await app.inject({
      method: 'POST',
      url: '/api/vouchers/discounts',
      headers: { cookie: ownerCookie },
      payload: { name: '', percent: 20 },
    });
    expect(badDiscount.statusCode).toBe(400);
  });

  it('a manager cannot open vouchers', async () => {
    const made = await app.inject({
      method: 'POST',
      url: '/api/users',
      headers: { cookie: ownerCookie },
      payload: { username: 'mgr1', role: 'manager', all_branches: true },
    });
    expect(made.statusCode).toBe(201);
    const login = await app.inject({
      method: 'POST',
      url: '/api/auth/login',
      payload: { username: 'mgr1', password: made.json().password },
    });
    expect(login.statusCode).toBe(200);
    const cookie = login.cookies.find((c) => c.name === SESSION_COOKIE);
    const res = await app.inject({
      method: 'GET',
      url: '/api/vouchers',
      headers: { cookie: `${SESSION_COOKIE}=${cookie?.value}` },
    });
    expect(res.statusCode).toBe(403);
  });

  it('says so when the voucher server is not connected', async () => {
    await app.close();
    const repo = new MemoryRepo();
    app = await buildApp({
      repo,
      storage: new Storage(join(dir, 'backups-2')),
      adminToken: 'admin',
      maxBackupBytes: 1024,
      vouchers: null,
    });
    const made = await app.inject({
      method: 'POST',
      url: '/v1/admin/shops',
      headers: { 'x-admin-token': 'admin' },
      payload: { name: 'Shop', branch: 'Main', owner: 'owner2' },
    });
    const owner = made.json().owner as { username: string; password: string };
    const login = await app.inject({
      method: 'POST',
      url: '/api/auth/login',
      payload: { username: owner.username, password: owner.password },
    });
    const cookie = login.cookies.find((c) => c.name === SESSION_COOKIE);
    const res = await app.inject({
      method: 'GET',
      url: '/api/vouchers',
      headers: { cookie: `${SESSION_COOKIE}=${cookie?.value}` },
    });
    expect(res.statusCode).toBe(503);
  });
});
