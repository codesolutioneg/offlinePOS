/// The server on an in-memory database, for trying the reports site and a till
/// against it on one machine. Nothing it holds survives a restart.
///
///   npx tsx scripts/dev-memory.ts [webDir]
///
/// Prints the owner's password and the branch pairing code it starts with.
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { buildApp } from '../src/app.js';
import { MemoryRepo } from '../src/repo.js';
import { Storage } from '../src/storage.js';

const adminToken = 'dev-admin-token';
const app = await buildApp({
  repo: new MemoryRepo(),
  storage: new Storage(mkdtempSync(join(tmpdir(), 'posbackup-dev-'))),
  adminToken,
  maxBackupBytes: 1024 * 1024 * 1024,
  webDir: process.argv[2] ?? '../build/web',
});

const made = await app.inject({
  method: 'POST',
  url: '/v1/admin/shops',
  headers: { 'x-admin-token': adminToken },
  payload: { name: 'Demo shop', branch: 'Main branch', owner: 'owner' },
});
const shop = made.json();
await app.listen({ port: Number(process.env.PORT ?? 4555), host: '127.0.0.1' });
console.log(`site:      http://127.0.0.1:${process.env.PORT ?? 4555}/`);
console.log(`owner:     ${shop.owner.username} / ${shop.owner.password}`);
console.log(`pair code: ${shop.branch.pair_code}`);
