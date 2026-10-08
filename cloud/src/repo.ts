import { randomUUID } from 'node:crypto';

export interface Shop {
  id: string;
  name: string;
  keyId: string | null;
  createdAt: Date;
}

export interface Branch {
  id: string;
  shopId: string;
  name: string;
  createdAt: Date;
}

export interface Device {
  id: string;
  shopId: string;
  branchId: string;
  deviceId: string;
  name: string;
  appVersion: string;
  lastSeenAt: Date;
  lastSyncAt: Date | null;
}

export interface DeviceStatus extends Device {
  lastBackupAt: Date | null;
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
  branches: number;
  devices: number;
  users: number;
  backups: number;
  bytes: number;
  lastBackupAt: Date | null;
}

export type Role = 'owner' | 'manager' | 'accountant';

export interface User {
  id: string;
  shopId: string;
  username: string;
  displayName: string;
  role: Role;
  allBranches: boolean;
  branchIds: string[];
  capabilities: string[];
  active: boolean;
  createdAt: Date;
  lastLoginAt: Date | null;
}

export interface UserWithHash extends User {
  passwordHash: string;
}

export type UserPatch = Partial<
  Pick<UserWithHash, 'displayName' | 'role' | 'allBranches' | 'branchIds' | 'capabilities' | 'active' | 'passwordHash'>
>;

export interface SyncRecord {
  kind: string;
  key: string;
  at: Date | null;
  payload: unknown;
}

export interface StoredRecord extends SyncRecord {
  branchId: string;
  updatedAt: Date;
}

/// Everything the API needs from the database, so the routes can be tested
/// without one.
export interface Repo {
  createShop(name: string): Promise<Shop>;
  listShops(): Promise<ShopSummary[]>;
  shopById(id: string): Promise<Shop | null>;
  /// Sets the shop's key id when it has none. Returns the key id the shop ends up with.
  claimKeyId(shopId: string, keyId: string): Promise<string>;

  createBranch(shopId: string, name: string, pairCodeHash: string): Promise<Branch>;
  setBranchPairCode(branchId: string, pairCodeHash: string): Promise<boolean>;
  branchByPairCode(pairCodeHash: string): Promise<Branch | null>;
  branchById(id: string): Promise<Branch | null>;
  listBranches(shopId: string): Promise<Branch[]>;
  renameBranch(id: string, name: string): Promise<void>;

  /// One row per till per shop: pairing again replaces the token and the branch.
  upsertDevice(d: {
    shopId: string;
    branchId: string;
    deviceId: string;
    name: string;
    appVersion: string;
    tokenHash: string;
  }): Promise<Device>;
  deviceByToken(tokenHash: string): Promise<Device | null>;
  touchDevice(id: string, at: Date): Promise<void>;
  markSynced(id: string, at: Date): Promise<void>;
  listDevices(shopId: string): Promise<DeviceStatus[]>;

  backupBySha(shopId: string, sha256: string): Promise<Backup | null>;
  addBackup(b: Omit<Backup, 'id' | 'receivedAt'> & { id?: string }): Promise<Backup>;
  listBackups(shopId: string): Promise<BackupListing[]>;
  backupById(shopId: string, id: string): Promise<Backup | null>;
  deviceBackups(deviceRowId: string): Promise<Backup[]>;
  deleteBackups(ids: string[]): Promise<void>;

  createUser(u: Omit<UserWithHash, 'id' | 'createdAt' | 'lastLoginAt'>): Promise<User>;
  userByUsername(username: string): Promise<UserWithHash | null>;
  userById(id: string): Promise<UserWithHash | null>;
  listUsers(shopId: string): Promise<User[]>;
  updateUser(id: string, patch: UserPatch): Promise<User | null>;
  deleteUser(id: string): Promise<void>;
  touchLogin(id: string, at: Date): Promise<void>;

  createSession(id: string, userId: string, expiresAt: Date): Promise<void>;
  /// The session's user while the session is live, null once it has lapsed.
  sessionUser(id: string, now: Date): Promise<UserWithHash | null>;
  extendSession(id: string, expiresAt: Date, at: Date): Promise<void>;
  deleteSession(id: string): Promise<void>;
  deleteUserSessions(userId: string, exceptId?: string): Promise<void>;

  upsertRecords(shopId: string, branchId: string, deviceRowId: string, records: SyncRecord[]): Promise<number>;
  queryRecords(q: {
    shopId: string;
    /// Null for every branch of the shop.
    branchIds: string[] | null;
    kinds: string[];
    from?: Date;
    to?: Date;
  }): Promise<StoredRecord[]>;
}

const pick = <T extends object, K extends keyof T>(o: T, omit: K[]): Omit<T, K> => {
  const copy = { ...o };
  for (const k of omit) delete copy[k];
  return copy;
};

/// For the tests.
export class MemoryRepo implements Repo {
  shops: Shop[] = [];
  branches: (Branch & { pairCodeHash: string })[] = [];
  devices: (Device & { tokenHash: string })[] = [];
  backups: Backup[] = [];
  users: UserWithHash[] = [];
  sessions: { id: string; userId: string; expiresAt: Date; lastSeenAt: Date }[] = [];
  records: (StoredRecord & { shopId: string; deviceRowId: string })[] = [];

  async createShop(name: string): Promise<Shop> {
    const shop = { id: randomUUID(), name, keyId: null, createdAt: new Date() };
    this.shops.push(shop);
    return { ...shop };
  }

  async listShops(): Promise<ShopSummary[]> {
    return this.shops.map((s) => {
      const backups = this.backups.filter((b) => b.shopId === s.id);
      return {
        ...s,
        branches: this.branches.filter((b) => b.shopId === s.id).length,
        devices: this.devices.filter((d) => d.shopId === s.id).length,
        users: this.users.filter((u) => u.shopId === s.id).length,
        backups: backups.length,
        bytes: backups.reduce((n, b) => n + b.size, 0),
        lastBackupAt: backups.length
          ? new Date(Math.max(...backups.map((b) => b.createdAt.getTime())))
          : null,
      };
    });
  }

  async shopById(id: string): Promise<Shop | null> {
    const shop = this.shops.find((s) => s.id === id);
    return shop ? { ...shop } : null;
  }

  async claimKeyId(shopId: string, keyId: string): Promise<string> {
    const shop = this.shops.find((s) => s.id === shopId)!;
    shop.keyId ??= keyId;
    return shop.keyId;
  }

  async createBranch(shopId: string, name: string, pairCodeHash: string): Promise<Branch> {
    const branch = { id: randomUUID(), shopId, name, createdAt: new Date(), pairCodeHash };
    this.branches.push(branch);
    return pick(branch, ['pairCodeHash']);
  }

  async setBranchPairCode(branchId: string, pairCodeHash: string): Promise<boolean> {
    const branch = this.branches.find((b) => b.id === branchId);
    if (!branch) return false;
    branch.pairCodeHash = pairCodeHash;
    return true;
  }

  async branchByPairCode(pairCodeHash: string): Promise<Branch | null> {
    const branch = this.branches.find((b) => b.pairCodeHash === pairCodeHash);
    return branch ? pick(branch, ['pairCodeHash']) : null;
  }

  async branchById(id: string): Promise<Branch | null> {
    const branch = this.branches.find((b) => b.id === id);
    return branch ? pick(branch, ['pairCodeHash']) : null;
  }

  async listBranches(shopId: string): Promise<Branch[]> {
    return this.branches.filter((b) => b.shopId === shopId).map((b) => pick(b, ['pairCodeHash']));
  }

  async renameBranch(id: string, name: string): Promise<void> {
    const branch = this.branches.find((b) => b.id === id);
    if (branch) branch.name = name;
  }

  async upsertDevice(d: {
    shopId: string;
    branchId: string;
    deviceId: string;
    name: string;
    appVersion: string;
    tokenHash: string;
  }): Promise<Device> {
    let device = this.devices.find((x) => x.shopId === d.shopId && x.deviceId === d.deviceId);
    if (device) {
      Object.assign(device, d, { lastSeenAt: new Date() });
    } else {
      device = { id: randomUUID(), lastSeenAt: new Date(), lastSyncAt: null, ...d };
      this.devices.push(device);
    }
    return pick(device, ['tokenHash']);
  }

  async deviceByToken(tokenHash: string): Promise<Device | null> {
    const device = this.devices.find((d) => d.tokenHash === tokenHash);
    return device ? pick(device, ['tokenHash']) : null;
  }

  async touchDevice(id: string, at: Date): Promise<void> {
    const device = this.devices.find((d) => d.id === id);
    if (device) device.lastSeenAt = at;
  }

  async markSynced(id: string, at: Date): Promise<void> {
    const device = this.devices.find((d) => d.id === id);
    if (device) device.lastSyncAt = at;
  }

  async listDevices(shopId: string): Promise<DeviceStatus[]> {
    return this.devices
      .filter((d) => d.shopId === shopId)
      .map((d) => {
        const mine = this.backups.filter((b) => b.deviceRowId === d.id);
        return {
          ...pick(d, ['tokenHash']),
          lastBackupAt: mine.length
            ? new Date(Math.max(...mine.map((b) => b.createdAt.getTime())))
            : null,
        };
      });
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

  async createUser(u: Omit<UserWithHash, 'id' | 'createdAt' | 'lastLoginAt'>): Promise<User> {
    if (this.users.some((x) => x.username === u.username)) {
      throw new UsernameTaken();
    }
    const user = { ...u, id: randomUUID(), createdAt: new Date(), lastLoginAt: null };
    this.users.push(user);
    return pick(user, ['passwordHash']);
  }

  async userByUsername(username: string): Promise<UserWithHash | null> {
    const user = this.users.find((u) => u.username === username);
    return user ? { ...user } : null;
  }

  async userById(id: string): Promise<UserWithHash | null> {
    const user = this.users.find((u) => u.id === id);
    return user ? { ...user } : null;
  }

  async listUsers(shopId: string): Promise<User[]> {
    return this.users.filter((u) => u.shopId === shopId).map((u) => pick(u, ['passwordHash']));
  }

  async updateUser(id: string, patch: UserPatch): Promise<User | null> {
    const user = this.users.find((u) => u.id === id);
    if (!user) return null;
    Object.assign(user, patch);
    return pick(user, ['passwordHash']);
  }

  async deleteUser(id: string): Promise<void> {
    this.users = this.users.filter((u) => u.id !== id);
    this.sessions = this.sessions.filter((s) => s.userId !== id);
  }

  async touchLogin(id: string, at: Date): Promise<void> {
    const user = this.users.find((u) => u.id === id);
    if (user) user.lastLoginAt = at;
  }

  async createSession(id: string, userId: string, expiresAt: Date): Promise<void> {
    this.sessions.push({ id, userId, expiresAt, lastSeenAt: new Date() });
  }

  async sessionUser(id: string, now: Date): Promise<UserWithHash | null> {
    const session = this.sessions.find((s) => s.id === id);
    if (!session || session.expiresAt <= now) return null;
    return this.userById(session.userId);
  }

  async extendSession(id: string, expiresAt: Date, at: Date): Promise<void> {
    const session = this.sessions.find((s) => s.id === id);
    if (session) Object.assign(session, { expiresAt, lastSeenAt: at });
  }

  async deleteSession(id: string): Promise<void> {
    this.sessions = this.sessions.filter((s) => s.id !== id);
  }

  async deleteUserSessions(userId: string, exceptId?: string): Promise<void> {
    this.sessions = this.sessions.filter((s) => s.userId !== userId || s.id === exceptId);
  }

  async upsertRecords(
    shopId: string,
    branchId: string,
    deviceRowId: string,
    records: SyncRecord[],
  ): Promise<number> {
    for (const r of records) {
      const row = { ...r, shopId, branchId, deviceRowId, updatedAt: new Date() };
      const i = this.records.findIndex((x) => x.shopId === shopId && x.kind === r.kind && x.key === r.key);
      if (i >= 0) this.records[i] = row;
      else this.records.push(row);
    }
    return records.length;
  }

  async queryRecords(q: {
    shopId: string;
    branchIds: string[] | null;
    kinds: string[];
    from?: Date;
    to?: Date;
  }): Promise<StoredRecord[]> {
    return this.records
      .filter((r) => r.shopId === q.shopId && q.kinds.includes(r.kind))
      .filter((r) => q.branchIds === null || q.branchIds.includes(r.branchId))
      .filter((r) => !q.from || (r.at !== null && r.at >= q.from))
      .filter((r) => !q.to || (r.at !== null && r.at < q.to))
      .map((r) => pick(r, ['shopId', 'deviceRowId']));
  }
}

export class UsernameTaken extends Error {
  constructor() {
    super('that username is taken');
  }
}
