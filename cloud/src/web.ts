import cookie from '@fastify/cookie';
import fastifyStatic from '@fastify/static';
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';

import { newPairCode, newToken, pairCodeHash, sha256 } from './codes.js';
import { fail, USERNAME, USERNAME_RULE } from './http.js';
import {
  burnPasswordCheck,
  hashPassword,
  MIN_PASSWORD_LENGTH,
  newPassword,
  verifyPassword,
} from './passwords.js';
import {
  branchScope,
  capabilitiesOf,
  DEFAULT_CAPABILITIES,
  isCapability,
  readableKinds,
  ROLES,
} from './permissions.js';
import { UsernameTaken, type Repo, type Role, type User, type UserPatch } from './repo.js';

export const SESSION_COOKIE = 'pos_session';
const SESSION_DAYS = 30;
const DAY = 24 * 60 * 60 * 1000;

declare module 'fastify' {
  interface FastifyRequest {
    user?: User;
    sessionId?: string;
  }
}

/// Too many wrong passwords for one username, or from one address, and that
/// username or address waits a quarter of an hour.
export class LoginThrottle {
  private readonly failures = new Map<string, number[]>();
  constructor(
    private readonly now: () => Date,
    private readonly window = 15 * 60 * 1000,
    private readonly perUser = 5,
    private readonly perAddress = 30,
  ) {}

  private recent(key: string): number[] {
    const cutoff = this.now().getTime() - this.window;
    const kept = (this.failures.get(key) ?? []).filter((t) => t > cutoff);
    this.failures.set(key, kept);
    return kept;
  }

  blocked(username: string, address: string): boolean {
    return (
      this.recent(`u:${username}`).length >= this.perUser ||
      this.recent(`a:${address}`).length >= this.perAddress
    );
  }

  fail(username: string, address: string) {
    for (const key of [`u:${username}`, `a:${address}`]) {
      this.recent(key).push(this.now().getTime());
    }
  }

  clear(username: string) {
    this.failures.delete(`u:${username}`);
  }
}

const userJson = (u: User) => ({
  id: u.id,
  username: u.username,
  display_name: u.displayName,
  role: u.role,
  all_branches: u.role === 'owner' || u.allBranches,
  branch_ids: u.branchIds,
  capabilities: capabilitiesOf(u),
  active: u.active,
  created_at: u.createdAt.toISOString(),
  last_login_at: u.lastLoginAt?.toISOString() ?? null,
});

export async function registerWeb(
  app: FastifyInstance,
  opts: { repo: Repo; now: () => Date; webDir?: string },
) {
  const { repo, now } = opts;
  const throttle = new LoginThrottle(now);
  const extended = new Map<string, number>();

  await app.register(cookie);

  const setSession = (req: FastifyRequest, reply: FastifyReply, token: string) =>
    reply.setCookie(SESSION_COOKIE, token, {
      path: '/',
      httpOnly: true,
      sameSite: 'lax',
      secure: req.protocol === 'https',
      maxAge: SESSION_DAYS * 24 * 60 * 60,
    });

  // A page on another site cannot make a signed-in browser change anything here.
  app.addHook('onRequest', async (req, reply) => {
    if (!req.url.startsWith('/api/') || req.method === 'GET' || req.method === 'HEAD') return;
    const origin = req.headers.origin;
    if (origin) {
      let host = '';
      try {
        host = new URL(origin).host;
      } catch {
        // An origin that is not a URL is as foreign as one that is.
      }
      if (host !== req.headers.host) return fail(reply, 403, 'cross-site request refused');
    }
  });

  async function signedIn(req: FastifyRequest, reply: FastifyReply) {
    const token = req.cookies[SESSION_COOKIE];
    const id = token ? sha256(token) : '';
    const user = id ? await repo.sessionUser(id, now()) : null;
    if (!user || !user.active) {
      return fail(reply, 401, 'sign in first');
    }
    const { passwordHash: _, ...plain } = user;
    req.user = plain;
    req.sessionId = id;
    // Sliding, but written at most every ten minutes.
    const last = extended.get(id) ?? 0;
    if (now().getTime() - last > 10 * 60 * 1000) {
      extended.set(id, now().getTime());
      await repo.extendSession(id, new Date(now().getTime() + SESSION_DAYS * DAY), now());
      setSession(req, reply, token!);
    }
  }

  async function ownerOnly(req: FastifyRequest, reply: FastifyReply) {
    if (req.user?.role !== 'owner') return fail(reply, 403, 'only the owner can do that');
  }

  const auth = { preHandler: signedIn };
  const owner = { preHandler: [signedIn, ownerOnly] };

  // ── Session ────────────────────────────────────────────────────────────

  app.post<{ Body: { username?: string; password?: string } }>('/api/auth/login', async (req, reply) => {
    const username = String(req.body?.username ?? '').trim().toLowerCase();
    const password = String(req.body?.password ?? '');
    if (!username || !password) return fail(reply, 400, 'enter the username and the password');
    if (throttle.blocked(username, req.ip)) {
      return fail(reply, 429, 'too many attempts; try again in 15 minutes');
    }
    const user = await repo.userByUsername(username);
    const ok = user ? await verifyPassword(password, user.passwordHash) : (await burnPasswordCheck(password), false);
    if (!user || !ok || !user.active) {
      throttle.fail(username, req.ip);
      return fail(reply, 401, 'wrong username or password');
    }
    throttle.clear(username);
    const token = newToken();
    await repo.createSession(sha256(token), user.id, new Date(now().getTime() + SESSION_DAYS * DAY));
    await repo.touchLogin(user.id, now());
    setSession(req, reply, token);
    const { passwordHash: _, ...plain } = user;
    return { user: userJson(plain) };
  });

  app.post('/api/auth/logout', async (req, reply) => {
    const token = req.cookies[SESSION_COOKIE];
    if (token) await repo.deleteSession(sha256(token));
    reply.clearCookie(SESSION_COOKIE, { path: '/' });
    return reply.code(204).send();
  });

  async function visibleBranches(user: User) {
    const all = await repo.listBranches(user.shopId);
    const scope = branchScope(user);
    return scope === null ? all : all.filter((b) => scope.includes(b.id));
  }

  app.get('/api/me', auth, async (req) => {
    const user = req.user!;
    const shop = (await repo.shopById(user.shopId))!;
    return {
      user: userJson(user),
      shop: { id: shop.id, name: shop.name },
      branches: (await visibleBranches(user)).map((b) => ({ id: b.id, name: b.name })),
    };
  });

  app.post<{ Body: { current?: string; next?: string } }>('/api/me/password', auth, async (req, reply) => {
    const user = (await repo.userById(req.user!.id))!;
    const next = String(req.body?.next ?? '');
    if (!(await verifyPassword(String(req.body?.current ?? ''), user.passwordHash))) {
      return fail(reply, 400, 'the current password is wrong');
    }
    if (next.length < MIN_PASSWORD_LENGTH) {
      return fail(reply, 400, `the new password needs at least ${MIN_PASSWORD_LENGTH} characters`);
    }
    await repo.updateUser(user.id, { passwordHash: await hashPassword(next) });
    await repo.deleteUserSessions(user.id, req.sessionId);
    return reply.code(204).send();
  });

  // ── Branches and devices ───────────────────────────────────────────────

  app.get('/api/branches', auth, async (req) => {
    const user = req.user!;
    const branches = await visibleBranches(user);
    const devices = await repo.listDevices(user.shopId);
    return {
      branches: branches.map((b) => ({
        id: b.id,
        name: b.name,
        devices: devices
          .filter((d) => d.branchId === b.id)
          .map((d) => ({
            id: d.deviceId,
            name: d.name,
            app_version: d.appVersion,
            last_seen_at: d.lastSeenAt.toISOString(),
            last_sync_at: d.lastSyncAt?.toISOString() ?? null,
            last_backup_at: d.lastBackupAt?.toISOString() ?? null,
          })),
      })),
    };
  });

  app.post<{ Body: { name?: string } }>('/api/branches', owner, async (req, reply) => {
    const name = String(req.body?.name ?? '').trim();
    if (!name) return fail(reply, 400, 'name is required');
    const code = newPairCode();
    const branch = await repo.createBranch(req.user!.shopId, name, pairCodeHash(code));
    return reply.code(201).send({ id: branch.id, name: branch.name, pair_code: code });
  });

  async function ownBranch(req: FastifyRequest<{ Params: { id: string } }>, reply: FastifyReply) {
    const branch = await repo.branchById(req.params.id);
    if (!branch || branch.shopId !== req.user!.shopId) {
      fail(reply, 404, 'no such branch');
      return null;
    }
    return branch;
  }

  app.patch<{ Params: { id: string }; Body: { name?: string } }>('/api/branches/:id', owner, async (req, reply) => {
    if (!(await ownBranch(req, reply))) return;
    const name = String(req.body?.name ?? '').trim();
    if (!name) return fail(reply, 400, 'name is required');
    await repo.renameBranch(req.params.id, name);
    return { id: req.params.id, name };
  });

  app.post<{ Params: { id: string } }>('/api/branches/:id/pair-code', owner, async (req, reply) => {
    if (!(await ownBranch(req, reply))) return;
    const code = newPairCode();
    await repo.setBranchPairCode(req.params.id, pairCodeHash(code));
    return { pair_code: code };
  });

  // ── The data behind the reports ────────────────────────────────────────

  app.get<{ Querystring: { kinds?: string; branch?: string; from?: string; to?: string } }>(
    '/api/records',
    auth,
    async (req, reply) => {
      const user = req.user!;
      const allowed = readableKinds(user);
      const kinds = String(req.query.kinds ?? '')
        .split(',')
        .map((k) => k.trim())
        .filter((k) => allowed.has(k));
      if (!kinds.length) return { records: [] };

      const scope = branchScope(user);
      const asked = String(req.query.branch ?? 'all');
      let branchIds: string[] | null;
      if (asked === 'all') {
        branchIds = scope;
      } else {
        const branch = await repo.branchById(asked);
        if (!branch || branch.shopId !== user.shopId || (scope !== null && !scope.includes(asked))) {
          return fail(reply, 403, 'that branch is not yours to see');
        }
        branchIds = [asked];
      }
      const parse = (v?: string) => {
        if (!v) return undefined;
        const d = new Date(v);
        return Number.isNaN(d.getTime()) ? null : d;
      };
      const from = parse(req.query.from);
      const to = parse(req.query.to);
      if (from === null || to === null) return fail(reply, 400, 'from and to must be ISO times');

      const records = await repo.queryRecords({
        shopId: user.shopId,
        branchIds,
        kinds,
        from,
        to,
      });
      return {
        records: records.map((r) => ({
          kind: r.kind,
          key: r.key,
          branch_id: r.branchId,
          at: r.at?.toISOString() ?? null,
          payload: r.payload,
        })),
      };
    },
  );

  // ── Users ──────────────────────────────────────────────────────────────

  interface UserBody {
    username?: string;
    display_name?: string;
    role?: string;
    password?: string;
    all_branches?: boolean;
    branch_ids?: string[];
    capabilities?: string[];
    active?: boolean;
  }

  /// The parts of [body] that are present, checked against the owner's shop.
  async function readUserBody(shopId: string, body: UserBody, reply: FastifyReply): Promise<UserPatch | null> {
    const patch: UserPatch = {};
    if (body.display_name !== undefined) {
      const name = String(body.display_name).trim();
      if (!name) return (fail(reply, 400, 'the name cannot be empty'), null);
      patch.displayName = name.slice(0, 80);
    }
    if (body.role !== undefined) {
      if (!ROLES.includes(body.role as Role)) return (fail(reply, 400, 'unknown role'), null);
      patch.role = body.role as Role;
    }
    if (body.all_branches !== undefined) patch.allBranches = Boolean(body.all_branches);
    if (body.branch_ids !== undefined) {
      if (!Array.isArray(body.branch_ids)) return (fail(reply, 400, 'branch_ids must be a list'), null);
      const mine = new Set((await repo.listBranches(shopId)).map((b) => b.id));
      const ids = body.branch_ids.map(String);
      if (ids.some((id) => !mine.has(id))) return (fail(reply, 400, 'unknown branch'), null);
      patch.branchIds = [...new Set(ids)];
    }
    if (body.capabilities !== undefined) {
      if (!Array.isArray(body.capabilities)) return (fail(reply, 400, 'capabilities must be a list'), null);
      const caps = body.capabilities.map(String);
      if (caps.some((c) => !isCapability(c))) return (fail(reply, 400, 'unknown capability'), null);
      patch.capabilities = [...new Set(caps)];
    }
    if (body.active !== undefined) patch.active = Boolean(body.active);
    if (body.password !== undefined && body.password !== '') {
      if (String(body.password).length < MIN_PASSWORD_LENGTH) {
        return (fail(reply, 400, `the password needs at least ${MIN_PASSWORD_LENGTH} characters`), null);
      }
      patch.passwordHash = await hashPassword(String(body.password));
    }
    return patch;
  }

  async function shopUser(req: FastifyRequest<{ Params: { id: string } }>, reply: FastifyReply) {
    const user = await repo.userById(req.params.id);
    if (!user || user.shopId !== req.user!.shopId) {
      fail(reply, 404, 'no such user');
      return null;
    }
    return user;
  }

  /// A shop is never left without an active owner to manage it.
  async function wouldOrphan(shopId: string, userId: string, after: UserPatch | 'deleted') {
    const owners = (await repo.listUsers(shopId)).filter((u) => u.role === 'owner' && u.active);
    if (!owners.some((u) => u.id === userId)) return false;
    const stillOwner =
      after !== 'deleted' && (after.role ?? 'owner') === 'owner' && (after.active ?? true);
    return !stillOwner && owners.length === 1;
  }

  app.get('/api/users', owner, async (req) => ({
    users: (await repo.listUsers(req.user!.shopId)).map(userJson),
  }));

  app.post<{ Body: UserBody }>('/api/users', owner, async (req, reply) => {
    const body = req.body ?? {};
    const username = String(body.username ?? '').trim().toLowerCase();
    if (!USERNAME.test(username)) return fail(reply, 400, USERNAME_RULE);
    const role = (body.role ?? 'manager') as Role;
    const patch = await readUserBody(req.user!.shopId, { ...body, role, password: undefined }, reply);
    if (!patch) return;
    const given = String(body.password ?? '');
    if (given && given.length < MIN_PASSWORD_LENGTH) {
      return fail(reply, 400, `the password needs at least ${MIN_PASSWORD_LENGTH} characters`);
    }
    const password = given || newPassword();
    try {
      const user = await repo.createUser({
        shopId: req.user!.shopId,
        username,
        displayName: patch.displayName ?? username,
        passwordHash: await hashPassword(password),
        role,
        allBranches: patch.allBranches ?? role === 'owner',
        branchIds: patch.branchIds ?? [],
        capabilities: patch.capabilities ?? DEFAULT_CAPABILITIES[role],
        active: patch.active ?? true,
      });
      return reply.code(201).send({ user: userJson(user), password: given ? null : password });
    } catch (e) {
      if (e instanceof UsernameTaken) return fail(reply, 409, 'that username is taken');
      throw e;
    }
  });

  app.patch<{ Params: { id: string }; Body: UserBody }>('/api/users/:id', owner, async (req, reply) => {
    const target = await shopUser(req, reply);
    if (!target) return;
    const patch = await readUserBody(req.user!.shopId, req.body ?? {}, reply);
    if (!patch) return;
    if (await wouldOrphan(target.shopId, target.id, patch)) {
      return fail(reply, 400, 'the shop needs at least one active owner');
    }
    const updated = (await repo.updateUser(target.id, patch))!;
    // Whatever changed, it applies from the next request, not the next sign-in.
    if (patch.active === false || patch.passwordHash) {
      await repo.deleteUserSessions(target.id, target.id === req.user!.id ? req.sessionId : undefined);
    }
    return { user: userJson(updated) };
  });

  app.post<{ Params: { id: string } }>('/api/users/:id/reset-password', owner, async (req, reply) => {
    const target = await shopUser(req, reply);
    if (!target) return;
    const password = newPassword();
    await repo.updateUser(target.id, { passwordHash: await hashPassword(password) });
    await repo.deleteUserSessions(target.id, target.id === req.user!.id ? req.sessionId : undefined);
    return { password };
  });

  app.delete<{ Params: { id: string } }>('/api/users/:id', owner, async (req, reply) => {
    const target = await shopUser(req, reply);
    if (!target) return;
    if (target.id === req.user!.id) return fail(reply, 400, 'you cannot delete yourself');
    if (await wouldOrphan(target.shopId, target.id, 'deleted')) {
      return fail(reply, 400, 'the shop needs at least one active owner');
    }
    await repo.deleteUser(target.id);
    return reply.code(204).send();
  });

  // ── The site itself ────────────────────────────────────────────────────

  const webDir = opts.webDir ? resolve(opts.webDir) : '';
  if (webDir && existsSync(webDir)) {
    await app.register(fastifyStatic, {
      root: webDir,
      wildcard: false,
      setHeaders(res, path) {
        // The shell is asked for fresh every time, so a new build is picked up on
        // the next visit; what it points at is versioned by the build.
        if (/index\.html$|flutter_service_worker\.js$|flutter_bootstrap\.js$|version\.json$/.test(path)) {
          res.setHeader('Cache-Control', 'no-cache');
        }
      },
    });
    app.get('/*', (req, reply) => {
      if (req.url.startsWith('/api/') || req.url.startsWith('/v1/')) {
        return fail(reply, 404, 'no such route');
      }
      return reply.sendFile('index.html');
    });
  }
}
