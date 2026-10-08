import Fastify, { type FastifyInstance, type FastifyReply, type FastifyRequest } from 'fastify';
import type { Readable } from 'node:stream';

import { newPairCode, newToken, pairCodeHash, sameSecret, sha256 } from './codes.js';
import { fail, USERNAME, USERNAME_RULE } from './http.js';
import { hashPassword, newPassword } from './passwords.js';
import { DEFAULT_CAPABILITIES, RECORD_KINDS, SNAPSHOT_KINDS } from './permissions.js';
import type { Device, Repo, SyncRecord } from './repo.js';
import { backupsToDelete } from './retention.js';
import { Storage, TooLarge } from './storage.js';
import { registerWeb } from './web.js';

export interface AppOptions {
  repo: Repo;
  storage: Storage;
  /// Guards the /v1/admin routes. Empty switches them off.
  adminToken: string;
  maxBackupBytes: number;
  now?: () => Date;
  logger?: boolean;
  /// Answers /health's database question.
  ping?: () => Promise<void>;
  /// The built reports site (flutter build web). Unset serves no site.
  webDir?: string;
}

const SHA256_HEX = /^[0-9a-f]{64}$/;
const SAFE_ID = /^[A-Za-z0-9_-]{1,64}$/;
export const MAX_SYNC_RECORDS = 500;

declare module 'fastify' {
  interface FastifyRequest {
    device?: Device;
  }
}

export async function buildApp(opts: AppOptions): Promise<FastifyInstance> {
  const { repo, storage } = opts;
  const now = opts.now ?? (() => new Date());
  const app = Fastify({
    logger: opts.logger ?? false,
    trustProxy: true,
    bodyLimit: 1024 * 1024,
  });

  // Handed to the route as the raw stream, so a large backup goes to disk
  // without ever sitting in memory whole.
  app.addContentTypeParser('application/octet-stream', (_req, payload, done) =>
    done(null, payload),
  );

  async function deviceAuth(req: FastifyRequest, reply: FastifyReply) {
    const header = req.headers.authorization ?? '';
    const token = header.startsWith('Bearer ') ? header.slice(7).trim() : '';
    const device = token ? await repo.deviceByToken(sha256(token)) : null;
    if (!device) return fail(reply, 401, 'this device is not paired, or its pairing was replaced');
    req.device = device;
    await repo.touchDevice(device.id, now());
  }

  async function adminAuth(req: FastifyRequest, reply: FastifyReply) {
    const given = String(req.headers['x-admin-token'] ?? '');
    if (!opts.adminToken || !given || !sameSecret(given, opts.adminToken)) {
      return fail(reply, 401, 'admin token required');
    }
  }

  app.get('/health', async (_req, reply) => {
    try {
      await opts.ping?.();
      return { ok: true };
    } catch {
      return fail(reply, 503, 'database unreachable');
    }
  });

  // ── Admin ──────────────────────────────────────────────────────────────

  /// A shop, its first branch and its owner, in one go. The pairing code and the
  /// owner's password are shown here once and stored only as hashes.
  app.post<{ Body: { name?: string; branch?: string; owner?: string } }>(
    '/v1/admin/shops',
    { preHandler: adminAuth },
    async (req, reply) => {
      const name = (req.body?.name ?? '').trim();
      if (!name) return fail(reply, 400, 'name is required');
      const owner = (req.body?.owner ?? '').trim().toLowerCase();
      if (owner && !USERNAME.test(owner)) return fail(reply, 400, USERNAME_RULE);
      if (owner && (await repo.userByUsername(owner))) return fail(reply, 409, 'that username is taken');

      const shop = await repo.createShop(name);
      const code = newPairCode();
      const branch = await repo.createBranch(
        shop.id,
        (req.body?.branch ?? '').trim() || name,
        pairCodeHash(code),
      );
      let created: { username: string; password: string } | null = null;
      if (owner) {
        const password = newPassword();
        await repo.createUser({
          shopId: shop.id,
          username: owner,
          displayName: owner,
          passwordHash: await hashPassword(password),
          role: 'owner',
          allBranches: true,
          branchIds: [],
          capabilities: DEFAULT_CAPABILITIES.owner,
          active: true,
        });
        created = { username: owner, password };
      }
      return reply.code(201).send({
        id: shop.id,
        name: shop.name,
        branch: { id: branch.id, name: branch.name, pair_code: code },
        owner: created,
      });
    },
  );

  app.get('/v1/admin/shops', { preHandler: adminAuth }, async () => ({
    shops: (await repo.listShops()).map((s) => ({
      id: s.id,
      name: s.name,
      key_id: s.keyId,
      branches: s.branches,
      devices: s.devices,
      users: s.users,
      backups: s.backups,
      bytes: s.bytes,
      last_backup_at: s.lastBackupAt?.toISOString() ?? null,
    })),
  }));

  app.post<{ Params: { id: string }; Body: { name?: string } }>(
    '/v1/admin/shops/:id/branches',
    { preHandler: adminAuth },
    async (req, reply) => {
      const shop = await repo.shopById(req.params.id);
      if (!shop) return fail(reply, 404, 'no such shop');
      const name = (req.body?.name ?? '').trim();
      if (!name) return fail(reply, 400, 'name is required');
      const code = newPairCode();
      const branch = await repo.createBranch(shop.id, name, pairCodeHash(code));
      return reply.code(201).send({ id: branch.id, name: branch.name, pair_code: code });
    },
  );

  app.post<{ Params: { id: string } }>(
    '/v1/admin/branches/:id/pair-code',
    { preHandler: adminAuth },
    async (req, reply) => {
      const code = newPairCode();
      if (!(await repo.setBranchPairCode(req.params.id, pairCodeHash(code)))) {
        return fail(reply, 404, 'no such branch');
      }
      return { pair_code: code };
    },
  );

  // ── Tills ──────────────────────────────────────────────────────────────

  app.post<{
    Body: { pair_code?: string; device_id?: string; device_name?: string; app_version?: string };
  }>('/v1/devices/pair', async (req, reply) => {
    const { pair_code, device_id, device_name, app_version } = req.body ?? {};
    if (!pair_code || !device_id) return fail(reply, 400, 'pair_code and device_id are required');
    const branch = await repo.branchByPairCode(pairCodeHash(pair_code));
    if (!branch) return fail(reply, 404, 'unknown pairing code');
    const shop = (await repo.shopById(branch.shopId))!;
    const token = newToken();
    await repo.upsertDevice({
      shopId: shop.id,
      branchId: branch.id,
      deviceId: String(device_id).slice(0, 100),
      name: String(device_name ?? device_id).slice(0, 100),
      appVersion: String(app_version ?? '').slice(0, 40),
      tokenHash: sha256(token),
    });
    return {
      token,
      shop: { id: shop.id, name: shop.name, key_id: shop.keyId },
      branch: { id: branch.id, name: branch.name },
    };
  });

  app.get('/v1/me', { preHandler: deviceAuth }, async (req) => {
    const shop = (await repo.shopById(req.device!.shopId))!;
    const branch = await repo.branchById(req.device!.branchId);
    return {
      shop: { id: shop.id, name: shop.name, key_id: shop.keyId },
      branch: branch ? { id: branch.id, name: branch.name } : null,
      device: { id: req.device!.deviceId, name: req.device!.name },
    };
  });

  /// The till's sales, shifts and the rest, as they change. Idempotent: the
  /// same record sent twice is stored once, so a till that never heard the
  /// answer simply sends the batch again.
  app.post<{ Body: { records?: unknown } }>(
    '/v1/sync',
    { preHandler: deviceAuth, bodyLimit: 16 * 1024 * 1024 },
    async (req, reply) => {
      const device = req.device!;
      const input = req.body?.records;
      if (!Array.isArray(input)) return fail(reply, 400, 'records must be a list');
      if (input.length > MAX_SYNC_RECORDS) {
        return fail(reply, 413, `at most ${MAX_SYNC_RECORDS} records per batch`);
      }
      const records: SyncRecord[] = [];
      for (const r of input as Record<string, unknown>[]) {
        const kind = String(r?.kind ?? '');
        if (!RECORD_KINDS.has(kind)) return fail(reply, 400, `unknown record kind: ${kind}`);
        // A branch's menu, costs and staff are one record per branch: keyed by
        // the branch the device belongs to, never by what it says.
        const key = SNAPSHOT_KINDS.has(kind) ? device.branchId : String(r?.key ?? '');
        if (!key || key.length > 200) return fail(reply, 400, 'every record needs a key');
        let at: Date | null = null;
        if (r.at !== null && r.at !== undefined) {
          at = new Date(String(r.at));
          if (Number.isNaN(at.getTime())) return fail(reply, 400, `bad time on ${kind} ${key}`);
        }
        if (r.payload === undefined || r.payload === null) {
          return fail(reply, 400, `no payload on ${kind} ${key}`);
        }
        records.push({ kind, key, at, payload: r.payload });
      }
      const stored = await repo.upsertRecords(device.shopId, device.branchId, device.id, records);
      await repo.markSynced(device.id, now());
      return { stored };
    },
  );

  app.post('/v1/backups', { preHandler: deviceAuth }, async (req, reply) => {
    const device = req.device!;
    if (!(req.body && typeof (req.body as Readable).pipe === 'function')) {
      return fail(reply, 415, 'send the backup as application/octet-stream');
    }
    const claimedSha = String(req.headers['x-backup-sha256'] ?? '').toLowerCase();
    const keyId = String(req.headers['x-backup-key-id'] ?? '');
    const reason = String(req.headers['x-backup-reason'] ?? '').slice(0, 40);
    const createdAt = new Date(String(req.headers['x-backup-created-at'] ?? ''));
    if (!SHA256_HEX.test(claimedSha)) return fail(reply, 400, 'X-Backup-Sha256 is required');
    if (!SAFE_ID.test(keyId)) return fail(reply, 400, 'X-Backup-Key-Id is required');
    if (Number.isNaN(createdAt.getTime())) return fail(reply, 400, 'X-Backup-Created-At is required');

    const shopKey = (await repo.shopById(device.shopId))!.keyId;
    if (shopKey && shopKey !== keyId) {
      return fail(reply, 409, 'this shop uses a different recovery key');
    }

    let received: { temp: string; size: number; sha256: string };
    try {
      received = await storage.receive(req.body as Readable, opts.maxBackupBytes);
    } catch (e) {
      if (e instanceof TooLarge) return fail(reply, 413, e.message);
      throw e;
    }
    // Dropped before answering, so nothing is left behind once the till hears back.
    const drop = async () => {
      await storage.discard(received.temp);
      received.temp = '';
    };
    try {
      if (received.sha256 !== claimedSha) {
        await drop();
        return fail(reply, 400, 'the backup arrived damaged (checksum mismatch); try again');
      }
      const existing = await repo.backupBySha(device.shopId, received.sha256);
      if (existing) {
        await drop();
        return reply.code(200).send({ id: existing.id, duplicate: true });
      }

      if ((await repo.claimKeyId(device.shopId, keyId)) !== keyId) {
        await drop();
        return fail(reply, 409, 'this shop uses a different recovery key');
      }

      const id = `${Date.now().toString(36)}${sha256(received.temp).slice(0, 10)}`;
      const path = `${device.shopId}/${id}.opcb`;
      await storage.commit(received.temp, path);
      received.temp = '';
      const backup = await repo.addBackup({
        id,
        shopId: device.shopId,
        deviceRowId: device.id,
        createdAt,
        size: received.size,
        sha256: received.sha256,
        reason,
        keyId,
        path,
      });

      await prune(device.id);
      return reply.code(201).send({ id: backup.id });
    } finally {
      if (received.temp) await storage.discard(received.temp);
    }
  });

  async function prune(deviceRowId: string) {
    const backups = await repo.deviceBackups(deviceRowId);
    const doomed = new Set(backupsToDelete(backups, now()));
    if (!doomed.size) return;
    await repo.deleteBackups([...doomed]);
    for (const b of backups) if (doomed.has(b.id)) await storage.discard(b.path);
  }

  app.get('/v1/backups', { preHandler: deviceAuth }, async (req) => ({
    backups: (await repo.listBackups(req.device!.shopId)).map((b) => ({
      id: b.id,
      device_id: b.deviceId,
      device_name: b.deviceName,
      created_at: b.createdAt.toISOString(),
      received_at: b.receivedAt.toISOString(),
      size: b.size,
      reason: b.reason,
      key_id: b.keyId,
    })),
  }));

  app.get<{ Params: { id: string } }>(
    '/v1/backups/:id',
    { preHandler: deviceAuth },
    async (req, reply) => {
      if (!SAFE_ID.test(req.params.id)) return fail(reply, 404, 'no such backup');
      const backup = await repo.backupById(req.device!.shopId, req.params.id);
      const size = backup ? await storage.size(backup.path) : null;
      if (!backup || size === null) return fail(reply, 404, 'no such backup');
      return reply
        .header('Content-Type', 'application/octet-stream')
        .header('Content-Length', size)
        .header('X-Backup-Sha256', backup.sha256)
        .send(storage.read(backup.path));
    },
  );

  await registerWeb(app, { repo, now, webDir: opts.webDir });
  return app;
}