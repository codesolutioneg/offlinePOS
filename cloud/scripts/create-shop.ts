// Make a shop and print its pairing code: npm run shop:create -- "Cairo branch"
import { PrismaClient } from '@prisma/client';

import { newPairCode, pairCodeHash } from '../src/codes.js';
import { PrismaRepo } from '../src/prisma-repo.js';

const name = process.argv.slice(2).join(' ').trim();
if (!name) {
  console.error('usage: npm run shop:create -- "<shop name>"');
  process.exit(1);
}

const prisma = new PrismaClient();
const code = newPairCode();
const shop = await new PrismaRepo(prisma).createShop(name, pairCodeHash(code));
console.log(`shop:      ${shop.name}`);
console.log(`id:        ${shop.id}`);
console.log(`pair code: ${code}`);
await prisma.$disconnect();
