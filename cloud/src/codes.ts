import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';

const ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

export const sha256 = (text: string | Buffer) => createHash('sha256').update(text).digest('hex');

/// `XXXX-XXXX-XXXX-XXXX`: 80 random bits, read aloud or typed off a phone.
export function newPairCode(): string {
  const bytes = randomBytes(16);
  let out = '';
  for (let i = 0; i < 16; i++) {
    if (i > 0 && i % 4 === 0) out += '-';
    out += ALPHABET[bytes[i] & 31];
  }
  return out;
}

/// The same code however it was typed.
export function normalisePairCode(code: string): string {
  return code
    .toUpperCase()
    .replace(/[\s-]/g, '')
    .replace(/O/g, '0')
    .replace(/[IL]/g, '1');
}

export const pairCodeHash = (code: string) => sha256(normalisePairCode(code));

export const newToken = () => randomBytes(32).toString('base64url');

export function sameSecret(a: string, b: string): boolean {
  const x = Buffer.from(sha256(a));
  const y = Buffer.from(sha256(b));
  return timingSafeEqual(x, y);
}
