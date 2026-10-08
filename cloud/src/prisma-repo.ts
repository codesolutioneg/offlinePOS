import { Prisma, PrismaClient } from '@prisma/client';

import type { Backup, BackupListing, Device, Repo, Shop, ShopSummary } from './repo.js';

type BackupRow = Prisma.BackupGetPayload<object>;

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

const shopFields = { id: true, name: true, keyId: true, createdAt: true } as const;
const deviceFields = {
  id: true,
  shopId: true,
  deviceId: true,
  name: true,
  appVersion: true,
  lastSeenAt: true,
} as const;

export class PrismaRepo implements Repo {
  constructor(private readonly db: PrismaClient) {}

  createShop(name: string, pairCodeHash: string): Promise<Shop> {
    return this.db.shop.create({ data: { name, pairCodeHash }, select: shopFields });
  }

  async setPairCode(shopId: string, pairCodeHash: string): Promise<boolean> {
    const { count } = await this.db.shop.updateMany({
      where: { id: shopId },
      data: { pairCodeHash },
    });
    return count > 0;
  }

  async listShops(): Promise<ShopSummary[]> {
    const shops = await this.db.shop.findMany({
      select: { ...shopFields, _count: { select: { devices: true } } },
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
        devices: _count.devices,
        backups: st?._count._all ?? 0,
        bytes: st?._sum.size ?? 0,
        lastBackupAt: st?._max.createdAt ?? null,
      };
    });
  }

  shopByPairCode(pairCodeHash: string): Promise<Shop | null> {
    return this.db.shop.findUnique({ where: { pairCodeHash }, select: shopFields });
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

  upsertDevice(d: {
    shopId: string;
    deviceId: string;
    name: string;
    appVersion: string;
    tokenHash: string;
  }): Promise<Device> {
    return this.db.device.upsert({
      where: { shopId_deviceId: { shopId: d.shopId, deviceId: d.deviceId } },
      create: d,
      update: {
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
}
