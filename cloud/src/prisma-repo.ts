import { Prisma, PrismaClient } from '@prisma/client';

import {
  UsernameTaken,
  type Backup,
  type BackupListing,
  type Branch,
  type Device,
  type DeviceStatus,
  type Repo,
  type Role,
  type Shop,
  type ShopSummary,
  type StoredRecord,
  type SyncRecord,
  type User,
  type UserPatch,
  type UserWithHash,
} from './repo.js';

type BackupRow = Prisma.BackupGetPayload<object>;
type UserRow = Prisma.UserGetPayload<object>;

const backup = (b: BackupRow): Backup => ({
  id: b.id,
  shopId: b.shopId,
  deviceRowId: b.deviceId,
  createdAt: b.createdAt,
  receivedAt: b.receivedAt,
  size: b.size,
  sha256: b.sha256,
  reason: b.reason,
  keyId: b.keyId,
  path: b.path,
});

const withHash = (u: UserRow): UserWithHash => ({ ...u, role: u.role as Role });
const user = (u: UserRow): User => {
  const { passwordHash: _, ...rest } = withHash(u);
  return rest;
};

const shopFields = { id: true, name: true, keyId: true, createdAt: true } as const;
const branchFields = { id: true, shopId: true, name: true, createdAt: true } as const;
const deviceFields = {
  id: true,
  shopId: true,
  branchId: true,
  deviceId: true,
  name: true,
  appVersion: true,
  lastSeenAt: true,
  lastSyncAt: true,
} as const;

export class PrismaRepo implements Repo {
  constructor(private readonly db: PrismaClient) {}

  createShop(name: string): Promise<Shop> {
    return this.db.shop.create({ data: { name }, select: shopFields });
  }

  async listShops(): Promise<ShopSummary[]> {
    const shops = await this.db.shop.findMany({
      select: {
        ...shopFields,
        _count: { select: { devices: true, branches: true, users: true } },
      },
      orderBy: { createdAt: 'asc' },
    });
    const stats = await this.db.backup.groupBy({
      by: ['shopId'],
      _count: { _all: true },
      _sum: { size: true },
      _max: { createdAt: true },
    });
    return shops.map(({ _count, ...s }) => {
      const st = stats.find((x) => x.shopId === s.id);
      return {
        ...s,
        branches: _count.branches,
        devices: _count.devices,
        users: _count.users,
        backups: st?._count._all ?? 0,
        bytes: st?._sum.size ?? 0,
        lastBackupAt: st?._max.createdAt ?? null,
      };
    });
  }

  shopById(id: string): Promise<Shop | null> {
    return this.db.shop.findUnique({ where: { id }, select: shopFields });
  }

  async claimKeyId(shopId: string, keyId: string): Promise<string> {
    // Conditional, so two tills uploading their first backup at once cannot both win.
    await this.db.shop.updateMany({ where: { id: shopId, keyId: null }, data: { keyId } });
    const shop = await this.db.shop.findUniqueOrThrow({ where: { id: shopId } });
    return shop.keyId!;
  }

  createBranch(shopId: string, name: string, pairCodeHash: string): Promise<Branch> {
    return this.db.branch.create({ data: { shopId, name, pairCodeHash }, select: branchFields });
  }

  async setBranchPairCode(branchId: string, pairCodeHash: string): Promise<boolean> {
    const { count } = await this.db.branch.updateMany({
      where: { id: branchId },
      data: { pairCodeHash },
    });
    return count > 0;
  }

  branchByPairCode(pairCodeHash: string): Promise<Branch | null> {
    return this.db.branch.findUnique({ where: { pairCodeHash }, select: branchFields });
  }

  branchById(id: string): Promise<Branch | null> {
    return this.db.branch.findUnique({ where: { id }, select: branchFields });
  }

  listBranches(shopId: string): Promise<Branch[]> {
    return this.db.branch.findMany({
      where: { shopId },
      select: branchFields,
      orderBy: { createdAt: 'asc' },
    });
  }

  async renameBranch(id: string, name: string): Promise<void> {
    await this.db.branch.updateMany({ where: { id }, data: { name } });
  }

  async deleteBranch(id: string): Promise<Backup[]> {
    return this.db.$transaction(async (tx) => {
      const gone = await tx.backup.findMany({ where: { device: { branchId: id } } });
      await tx.record.deleteMany({ where: { branchId: id } });
      // Devices go with the branch, and their backups with them.
      await tx.branch.deleteMany({ where: { id } });
      const holders = await tx.user.findMany({
        where: { branchIds: { has: id } },
        select: { id: true, branchIds: true },
      });
      for (const u of holders) {
        await tx.user.update({
          where: { id: u.id },
          data: { branchIds: u.branchIds.filter((b) => b !== id) },
        });
      }
      return gone.map(backup);
    });
  }

  upsertDevice(d: {
    shopId: string;
    branchId: string;
    deviceId: string;
    name: string;
    appVersion: string;
    tokenHash: string;
  }): Promise<Device> {
    return this.db.device.upsert({
      where: { shopId_deviceId: { shopId: d.shopId, deviceId: d.deviceId } },
      create: d,
      update: {
        branchId: d.branchId,
        name: d.name,
        appVersion: d.appVersion,
        tokenHash: d.tokenHash,
        lastSeenAt: new Date(),
      },
      select: deviceFields,
    });
  }

  deviceByToken(tokenHash: string): Promise<Device | null> {
    return this.db.device.findUnique({ where: { tokenHash }, select: deviceFields });
  }

  async touchDevice(id: string, at: Date): Promise<void> {
    await this.db.device.updateMany({ where: { id }, data: { lastSeenAt: at } });
  }

  async markSynced(id: string, at: Date): Promise<void> {
    await this.db.device.updateMany({ where: { id }, data: { lastSyncAt: at } });
  }

  async listDevices(shopId: string): Promise<DeviceStatus[]> {
    const devices = await this.db.device.findMany({
      where: { shopId },
      select: deviceFields,
      orderBy: { createdAt: 'asc' },
    });
    const last = await this.db.backup.groupBy({
      by: ['deviceId'],
      where: { shopId },
      _max: { createdAt: true },
    });
    return devices.map((d) => ({
      ...d,
      lastBackupAt: last.find((l) => l.deviceId === d.id)?._max.createdAt ?? null,
    }));
  }

  async backupBySha(shopId: string, sha256: string): Promise<Backup | null> {
    const b = await this.db.backup.findUnique({ where: { shopId_sha256: { shopId, sha256 } } });
    return b ? backup(b) : null;
  }

  async addBackup(b: Omit<Backup, 'id' | 'receivedAt'> & { id?: string }): Promise<Backup> {
    const row = await this.db.backup.create({
      data: {
        id: b.id,
        shopId: b.shopId,
        deviceId: b.deviceRowId,
        createdAt: b.createdAt,
        size: b.size,
        sha256: b.sha256,
        reason: b.reason,
        keyId: b.keyId,
        path: b.path,
      },
    });
    return backup(row);
  }

  async listBackups(shopId: string): Promise<BackupListing[]> {
    const rows = await this.db.backup.findMany({
      where: { shopId },
      include: { device: { select: { deviceId: true, name: true } } },
      orderBy: { createdAt: 'desc' },
    });
    return rows.map(({ device, ...b }) => ({
      ...backup(b),
      deviceId: device.deviceId,
      deviceName: device.name,
    }));
  }

  async backupById(shopId: string, id: string): Promise<Backup | null> {
    const b = await this.db.backup.findFirst({ where: { id, shopId } });
    return b ? backup(b) : null;
  }

  async deviceBackups(deviceRowId: string): Promise<Backup[]> {
    const rows = await this.db.backup.findMany({ where: { deviceId: deviceRowId } });
    return rows.map(backup);
  }

  async deleteBackups(ids: string[]): Promise<void> {
    if (ids.length) await this.db.backup.deleteMany({ where: { id: { in: ids } } });
  }

  async createUser(u: Omit<UserWithHash, 'id' | 'createdAt' | 'lastLoginAt'>): Promise<User> {
    try {
      return user(await this.db.user.create({ data: u }));
    } catch (e) {
      if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === 'P2002') {
        throw new UsernameTaken();
      }
      throw e;
    }
  }

  async userByUsername(username: string): Promise<UserWithHash | null> {
    const u = await this.db.user.findUnique({ where: { username } });
    return u ? withHash(u) : null;
  }

  async userById(id: string): Promise<UserWithHash | null> {
    const u = await this.db.user.findUnique({ where: { id } });
    return u ? withHash(u) : null;
  }

  async listUsers(shopId: string): Promise<User[]> {
    const rows = await this.db.user.findMany({ where: { shopId }, orderBy: { createdAt: 'asc' } });
    return rows.map(user);
  }

  async updateUser(id: string, patch: UserPatch): Promise<User | null> {
    try {
      return user(await this.db.user.update({ where: { id }, data: patch }));
    } catch (e) {
      if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === 'P2025') return null;
      throw e;
    }
  }

  async deleteUser(id: string): Promise<void> {
    await this.db.user.deleteMany({ where: { id } });
  }

  async touchLogin(id: string, at: Date): Promise<void> {
    await this.db.user.updateMany({ where: { id }, data: { lastLoginAt: at } });
  }

  async createSession(id: string, userId: string, expiresAt: Date): Promise<void> {
    await this.db.session.create({ data: { id, userId, expiresAt } });
  }

  async sessionUser(id: string, now: Date): Promise<UserWithHash | null> {
    const s = await this.db.session.findUnique({ where: { id }, include: { user: true } });
    if (!s || s.expiresAt <= now) return null;
    return withHash(s.user);
  }

  async extendSession(id: string, expiresAt: Date, at: Date): Promise<void> {
    await this.db.session.updateMany({ where: { id }, data: { expiresAt, lastSeenAt: at } });
  }

  async deleteSession(id: string): Promise<void> {
    await this.db.session.deleteMany({ where: { id } });
  }

  async deleteUserSessions(userId: string, exceptId?: string): Promise<void> {
    await this.db.session.deleteMany({
      where: { userId, ...(exceptId ? { NOT: { id: exceptId } } : {}) },
    });
  }

  async upsertRecords(
    shopId: string,
    branchId: string,
    deviceRowId: string,
    records: SyncRecord[],
  ): Promise<number> {
    if (!records.length) return 0;
    // One statement for the batch: a till catching up after a week offline sends
    // thousands, and a round trip each would keep it busy for minutes.
    const rows = records.map(
      (r) =>
        Prisma.sql`(${shopId}, ${branchId}, ${deviceRowId}, ${r.kind}, ${r.key}, ${r.at}, ${JSON.stringify(r.payload)}::jsonb, now())`,
    );
    return this.db.$executeRaw`
      INSERT INTO records (shop_id, branch_id, device_row_id, kind, key, at, payload, updated_at)
      VALUES ${Prisma.join(rows)}
      ON CONFLICT (shop_id, kind, key) DO UPDATE SET
        branch_id = EXCLUDED.branch_id,
        device_row_id = EXCLUDED.device_row_id,
        at = EXCLUDED.at,
        payload = EXCLUDED.payload,
        updated_at = now()`;
  }

  async queryRecords(q: {
    shopId: string;
    branchIds: string[] | null;
    kinds: string[];
    from?: Date;
    to?: Date;
  }): Promise<StoredRecord[]> {
    const rows = await this.db.record.findMany({
      where: {
        shopId: q.shopId,
        kind: { in: q.kinds },
        ...(q.branchIds === null ? {} : { branchId: { in: q.branchIds } }),
        ...(q.from || q.to
          ? { at: { ...(q.from ? { gte: q.from } : {}), ...(q.to ? { lt: q.to } : {}) } }
          : {}),
      },
      select: { kind: true, key: true, at: true, payload: true, branchId: true, updatedAt: true },
      orderBy: { at: 'asc' },
    });
    return rows;
  }
}
