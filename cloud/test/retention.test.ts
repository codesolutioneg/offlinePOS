import { describe, expect, it } from 'vitest';

import { backupsToDelete } from '../src/retention.js';

const now = new Date('2026-10-08T12:00:00Z');
const H = 3600_000;
const D = 24 * H;
const at = (msAgo: number, id = `b${msAgo}`) => ({ id, createdAt: new Date(now.getTime() - msAgo) });

describe('backupsToDelete', () => {
  it('keeps everything from the last 48 hours', () => {
    const backups = Array.from({ length: 48 }, (_, i) => at(i * H));
    expect(backupsToDelete(backups, now)).toEqual([]);
  });

  it('keeps the newest of each day for a month', () => {
    const backups = [at(3 * D + 2 * H, 'new'), at(3 * D + 5 * H, 'old'), at(4 * D, 'other-day')];
    expect(backupsToDelete(backups, now)).toEqual(['old']);
  });

  it('keeps the newest of each month for a year, then of each year', () => {
    const sept = (day: number) => ({
      id: `sep${day}`,
      createdAt: new Date(Date.UTC(2026, 7, day, 10)), // August: 40-70 days back
    });
    const years = [
      { id: 'y2024a', createdAt: new Date(Date.UTC(2024, 5, 1)) },
      { id: 'y2024b', createdAt: new Date(Date.UTC(2024, 2, 1)) },
    ];
    const doomed = backupsToDelete([at(0, 'latest'), sept(20), sept(10), sept(2), ...years], now);
    expect(doomed.sort()).toEqual(['sep10', 'sep2', 'y2024b']);
  });

  it('never deletes the last backup a till made, however old', () => {
    expect(backupsToDelete([at(900 * D, 'only')], now)).toEqual([]);
  });
});
