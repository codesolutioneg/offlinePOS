import { PrismaClient } from '@prisma/client';

import { buildApp } from './app.js';
import { config } from './config.js';
import { PrismaRepo } from './prisma-repo.js';
import { Storage } from './storage.js';

const cfg = config();
const prisma = new PrismaClient();
const app = await buildApp({
  repo: new PrismaRepo(prisma),
  storage: new Storage(cfg.storageDir),
  adminToken: cfg.adminToken,
  maxBackupBytes: cfg.maxBackupBytes,
  webDir: cfg.webDir,
  logger: true,
  ping: async () => {
    await prisma.$queryRaw`SELECT 1`;
  },
});

const stop = async () => {
  await app.close();
  await prisma.$disconnect();
  process.exit(0);
};
process.on('SIGTERM', stop);
process.on('SIGINT', stop);

await app.listen({ port: cfg.port, host: cfg.host });
