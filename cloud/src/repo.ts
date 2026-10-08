import { randomUUID } from 'node:crypto';

export interface Shop {
  id: string;
  name: string;
  keyId: string | null;
  createdAt: Date;
}

export interface Device {
  id: string;
  shopId: string;
  deviceId: string;
  name: string;
  appVersion: string;
  lastSeenAt: Date;
}

export interface Backup {
  id: string;
  shopId: string;
  deviceRowId: string;
  createdAt: Date;
  receivedAt: Date;
  size: number;
  sha256: string;
  reason: string;
  keyId: string;
  path: string;
}

export interface BackupListing extends Backup {
  deviceId: string;
  deviceName: string;
}

export interface ShopSummary extends Shop {
  devices: number;
  backups: number;
  bytes: number;
  lastBackupAt: Date | null;
}

/// Everything the API needs from the database, so the routes can be tested
/// without one.
export interface Repo {
  createShop(name: string, pairCodeHash: string): Promise<Shop>;
  setPairCode(shopId: string, pairCodeHash: string): Promise<boolean>;
  listShops(): Promise<ShopSummary[]>;
  shopByPairCode(pairCodeHash: string): Promise<Shop | null>;
  shopById(id: string): Promise<Shop | null>;
  /// Sets the shop's key id when it has none. Returns the key id the shop ends up with.
  claimKeyId(shopId: string, keyId: string): Promise<string>;

  /// One row per till per shop: pairing again replaces the token.
  upsertDevice(d: {
    shopId: string;
    deviceId: string;
    name: string;
    appVersion: string;
    tokenHash: string;
  }): Promise<Device>;
  deviceByToken(tokenHash: string): Promise<Device | null>;
  touchDevice(id: string, at: Date): Promise<void>;

  backupBySha(shopId: string, sha256: string): Promise<Backup | null>;
  addBackup(b: Omit<Backup, 'id' | 'receivedAt'> & { id?: string }): Promise<Backup>;
  listBackups(shopId: string): Promise<BackupListing[]>;
  backupById(shopId: string, id: string): Promise<Backup | null>;
  deviceBackups(deviceRowId: string): Promise<Backup[]>;
  deleteBackups(ids: string[]): Promise<void>;
}

/// For the tests.
export class MemoryRepo implements Repo {
  shops: (Shop & { pairCodeHash: string })[] = [];
  devices: (Device & { tokenHash: string })[] = [];
  backups: Backup[] = [];

  async createShop(name: string, pairCodeHash: string): Promise<Shop> {
    const shop = { id: randomUUID(), name, keyId: null, createdAt: new Date(), pairCodeHash };
    this.shops.push(shop);
    return strip(shop);
  }

  async setPairCode(shopId: string, pairCodeHash: string): Promise<boolean> {
    const shop = this.shops.find((s) => s.id === shopId);
    if (!shop) return false;
    shop.pairCodeHash = pairCodeHash;
    return true;
  }

  async listShops(): Promise<ShopSummary[]> {
    return this.shops.map((s) => {
      const backups = this.backups.filter((b) => b.shopId === s.id);
      return {
        ...strip(s),
        devices: this.devices.filter((d) => d.shopId === s.id).length,
        backups: backups.length,
        bytes: backups.reduce((n, b) => n + b.size, 0),
        lastBackupAt: backups.length
          ? new Date(Math.max(...backups.map((b) => b.createdAt.getTime())))
          : null,
      };
    });
  }

  async shopByPairCode(pairCodeHash: string): Promise<Shop | null> {
    const shop = this.shops.find((s) => s.pairCodeHash === pairCodeHash);
    return shop ? strip(shop) : null;
  }

  async shopById(id: string): Promise<Shop | null> {
    const shop = this.shops.find((s) => s.id === id);
    return shop ? strip(shop) : null;
  }

  async claimKeyId(shopId: string, keyId: string): Promise<string> {
    const shop = this.shops.find((s) => s.id === shopId)!;
    shop.keyId ??= keyId;
    return shop.keyId;
  }

  async upsertDevice(d: {
    shopId: string;
    deviceId: string;
    name: string;
    appVersion: string;
    tokenHash: string;
  }): Promise<Device> {
    let device = this.devices.find((x) => x.shopId === d.shopId && x.deviceId === d.deviceId);
    if (device) {
      Object.assign(device, d, { lastSeenAt: new Date() });
    } else {
      device = { id: randomUUID(), lastSeenAt: new Date(), ...d };
      this.devices.push(device);
    }
    const { tokenHash: _, ...rest } = device;
    return rest;
  }

  async deviceByToken(tokenHash: string): Promise<Device | null> {
    const device = this.devices.find((d) => d.tokenHash === tokenHash);
    if (!device) return null;
    const { tokenHash: _, ...rest } = device;
    return rest;
  }

  async touchDevice(id: string, at: Date): Promise<void> {
    const device = this.devices.find((d) => d.id === id);
    if (device) device.lastSeenAt = at;
  }

  async backupBySha(shopId: string, sha256: string): Promise<Backup | null> {
    return this.backups.find((b) => b.shopId === shopId && b.sha256 === sha256) ?? null;
  }

  async addBackup(b: Omit<Backup, 'id' | 'receivedAt'> & { id?: string }): Promise<Backup> {
    const backup = { ...b, id: b.id ?? randomUUID(), receivedAt: new Date() };
    this.backups.push(backup);
    return backup;
  }

  async listBackups(shopId: string): Promise<BackupListing[]> {
    return this.backups
      .filter((b) => b.shopId === shopId)
      .sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime())
      .map((b) => {
        const device = this.devices.find((d) => d.id === b.deviceRowId)!;
        return { ...b, deviceId: device.deviceId, deviceName: device.name };
      });
  }

  async backupById(shopId: string, id: string): Promise<Backup | null> {
    return this.backups.find((b) => b.shopId === shopId && b.id === id) ?? null;
  }

  async deviceBackups(deviceRowId: string): Promise<Backup[]> {
    return this.backups.filter((b) => b.deviceRowId === deviceRowId);
  }

  async deleteBackups(ids: string[]): Promise<void> {
    this.backups = this.backups.filter((b) => !ids.includes(b.id));
  }
}

function strip(s: Shop & { pairCodeHash: string }): Shop {
  const { pairCodeHash: _, ...shop } = s;
  return shop;
}
