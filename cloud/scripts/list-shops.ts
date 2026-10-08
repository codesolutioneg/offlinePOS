// Every shop, its tills and how its backups stand: npm run shop:list
import { PrismaClient } from '@prisma/client';

import { PrismaRepo } from '../src/prisma-repo.js';

const prisma = new PrismaClient();
const shops = await new PrismaRepo(prisma).listShops();
console.table(
  shops.map((s) => ({
    id: s.id,
    name: s.name,
    devices: s.devices,
    backups: s.backups,
    MB: (s.bytes / 1024 / 1024).toFixed(1),
    last: s.lastBackupAt?.toISOString() ?? '-',
  })),
);
await prisma.$disconnect();
