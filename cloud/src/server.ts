import { PrismaClient } from '@prisma/client';

import { buildApp } from './app.js';
import { config } from './config.js';
import { PrismaRepo } from './prisma-repo.js';
import { Storage } from './storage.js';
import { TaxService } from './tax/service.js';
import { voucherAdmin } from './voucher_admin.js';

const cfg = config();
const prisma = new PrismaClient();
const tax =
  cfg.firebaseProjectId && (cfg.firebaseCredentialsFile || cfg.firebaseCredentialsJson)
    ? new TaxService(prisma, {
        projectId: cfg.firebaseProjectId,
        credentialsFile: cfg.firebaseCredentialsFile,
        credentialsJson: cfg.firebaseCredentialsJson,
        etaProxyBase: cfg.etaProxyBase || `https://${cfg.firebaseProjectId}.web.app`,
        defaultConnectionId: cfg.taxDefaultConnectionId,
      })
    : null;
const app = await buildApp({
  repo: new PrismaRepo(prisma),
  storage: new Storage(cfg.storageDir),
  adminToken: cfg.adminToken,
  maxBackupBytes: cfg.maxBackupBytes,
  webDir: cfg.webDir,
  vouchers: voucherAdmin(cfg.voucherBaseUrl, cfg.voucherAdminKey),
  tax,
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
