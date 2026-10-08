import { createHash, randomUUID } from 'node:crypto';
import { createReadStream, createWriteStream } from 'node:fs';
import { mkdir, rename, rm, stat } from 'node:fs/promises';
import { dirname, join, resolve, sep } from 'node:path';
import { Transform, type Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';

export class TooLarge extends Error {}

/// Backups on disk, one file each, under one directory per shop.
export class Storage {
  readonly root: string;

  constructor(root: string) {
    this.root = resolve(root);
  }

  private abs(rel: string): string {
    const p = resolve(this.root, rel);
    if (!p.startsWith(this.root + sep)) throw new Error(`path escapes storage: ${rel}`);
    return p;
  }

  /// Streams [body] into a scratch file, hashing as it goes, without holding it
  /// in memory. The caller keeps it with [commit] or drops it with [discard].
  async receive(
    body: Readable,
    maxBytes: number,
  ): Promise<{ temp: string; size: number; sha256: string }> {
    const temp = join('.incoming', `${randomUUID()}.part`);
    const abs = this.abs(temp);
    await mkdir(dirname(abs), { recursive: true });
    const hash = createHash('sha256');
    let size = 0;
    // Past the limit the rest is read and dropped rather than the request torn
    // down, so the till gets a 413 it can show instead of a reset connection.
    const meter = new Transform({
      transform(chunk: Buffer, _enc, done) {
        size += chunk.length;
        if (size > maxBytes) return done();
        hash.update(chunk);
        done(null, chunk);
      },
    });
    try {
      await pipeline(body, meter, createWriteStream(abs));
    } catch (e) {
      await rm(abs, { force: true });
      throw e;
    }
    if (size > maxBytes) {
      await rm(abs, { force: true });
      throw new TooLarge(`backup is over ${maxBytes} bytes`);
    }
    return { temp, size, sha256: hash.digest('hex') };
  }

  async commit(temp: string, rel: string): Promise<void> {
    const to = this.abs(rel);
    await mkdir(dirname(to), { recursive: true });
    await rename(this.abs(temp), to);
  }

  async discard(rel: string): Promise<void> {
    await rm(this.abs(rel), { force: true });
  }

  async size(rel: string): Promise<number | null> {
    try {
      return (await stat(this.abs(rel))).size;
    } catch {
      return null;
    }
  }

  read(rel: string): Readable {
    return createReadStream(this.abs(rel));
  }
}
