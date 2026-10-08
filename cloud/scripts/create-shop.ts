// A shop, its first branch and its owner:
//   node dist/scripts/create-shop.js "<shop name>" "<first branch>" <owner username>
// Prints the branch's pairing code and the owner's password, once.
import { PrismaClient } from '@prisma/client';

import { newPairCode, pairCodeHash } from '../src/codes.js';
import { USERNAME, USERNAME_RULE } from '../src/http.js';
import { hashPassword, newPassword } from '../src/passwords.js';
import { DEFAULT_CAPABILITIES } from '../src/permissions.js';
import { PrismaRepo } from '../src/prisma-repo.js';

const [name, branchName, ownerArg] = process.argv.slice(2).map((a) => a.trim());
const owner = (ownerArg ?? '').toLowerCase();
if (!name || !branchName || !owner) {
  console.error('usage: create-shop "<shop name>" "<first branch>" <owner username>');
  process.exit(1);
}
if (!USERNAME.test(owner)) {
  console.error(USERNAME_RULE);
  process.exit(1);
}

const prisma = new PrismaClient();
const repo = new PrismaRepo(prisma);
if (await repo.userByUsername(owner)) {
  console.error(`the username ${owner} is taken`);
  process.exit(1);
}
const shop = await repo.createShop(name);
const code = newPairCode();
const branch = await repo.createBranch(shop.id, branchName, pairCodeHash(code));
const password = newPassword();
await repo.createUser({
  shopId: shop.id,
  username: owner,
  displayName: owner,
  passwordHash: await hashPassword(password),
  role: 'owner',
  allBranches: true,
  branchIds: [],
  capabilities: DEFAULT_CAPABILITIES.owner,
  active: true,
});
console.log(`shop:            ${shop.name} (${shop.id})`);
console.log(`branch:          ${branch.name}`);
console.log(`pair code:       ${code}`);
console.log(`owner username:  ${owner}`);
console.log(`owner password:  ${password}`);
await prisma.$disconnect();
