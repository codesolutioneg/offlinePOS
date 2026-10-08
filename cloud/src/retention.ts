export interface Dated {
  id: string;
  createdAt: Date;
}

const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;

/// Which of one till's backups to let go.
///
/// Everything from the last 48 hours stays. Past that, the newest of each day for
/// 30 days, the newest of each month for a year, and the newest of each year after
/// that. The newest backup of all is never deleted, however old: a till that died
/// a year ago still has its last copy.
export function backupsToDelete(backups: Dated[], now: Date): string[] {
  if (backups.length === 0) return [];
  const sorted = [...backups].sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime());
  const keep = new Set<string>([sorted[0].id]);
  const seen = new Set<string>();

  for (const b of sorted) {
    const age = now.getTime() - b.createdAt.getTime();
    const d = b.createdAt;
    let bucket: string;
    if (age <= 48 * HOUR) {
      keep.add(b.id);
      continue;
    } else if (age <= 30 * DAY) {
      bucket = `d:${d.getUTCFullYear()}-${d.getUTCMonth()}-${d.getUTCDate()}`;
    } else if (age <= 365 * DAY) {
      bucket = `m:${d.getUTCFullYear()}-${d.getUTCMonth()}`;
    } else {
      bucket = `y:${d.getUTCFullYear()}`;
    }
    // Newest first, so the first one into a bucket is the one kept.
    if (!seen.has(bucket)) {
      seen.add(bucket);
      keep.add(b.id);
    }
  }
  return sorted.filter((b) => !keep.has(b.id)).map((b) => b.id);
}
