/// Firebase Admin for Dishflow tax data. Credentials stay on the API host —
/// never sent to the browser.
import { readFileSync, existsSync } from 'node:fs';
import { cert, getApps, initializeApp, type App } from 'firebase-admin/app';
import { getFirestore as getFs, type Firestore } from 'firebase-admin/firestore';

export type TaxFirebaseConfig = {
  projectId: string;
  /** Absolute path to a service-account JSON, or empty. */
  credentialsFile: string;
  /** Raw JSON string of a service account, or empty. */
  credentialsJson: string;
};

const APP_NAME = 'tax-upload';
let app: App | null = null;

export function taxFirebaseReady(cfg: TaxFirebaseConfig): boolean {
  return Boolean(cfg.projectId && (cfg.credentialsFile || cfg.credentialsJson));
}

export function getFirestore(cfg: TaxFirebaseConfig): Firestore {
  if (!taxFirebaseReady(cfg)) {
    throw new Error('Firebase tax credentials are not set on the server');
  }
  if (!app) {
    const existing = getApps().find((a) => a.name === APP_NAME);
    if (existing) {
      app = existing;
    } else {
      let sa: object;
      if (cfg.credentialsFile) {
        if (!existsSync(cfg.credentialsFile)) {
          throw new Error(`Firebase credentials file missing: ${cfg.credentialsFile}`);
        }
        sa = JSON.parse(readFileSync(cfg.credentialsFile, 'utf8')) as object;
      } else {
        sa = JSON.parse(cfg.credentialsJson) as object;
      }
      app = initializeApp(
        { credential: cert(sa as Parameters<typeof cert>[0]), projectId: cfg.projectId },
        APP_NAME,
      );
    }
  }
  return getFs(app);
}

function asDate(value: unknown): Date | null {
  if (value == null) return null;
  if (value instanceof Date) return value;
  if (typeof value === 'string') {
    const d = new Date(value);
    return Number.isNaN(d.getTime()) ? null : d;
  }
  if (typeof value === 'object') {
    const maybe = value as { toDate?: () => Date; seconds?: unknown; _seconds?: unknown };
    if (typeof maybe.toDate === 'function') {
      try {
        return maybe.toDate();
      } catch {
        /* fall through */
      }
    }
    const sec = Number(maybe.seconds ?? maybe._seconds);
    if (Number.isFinite(sec)) return new Date(sec * 1000);
  }
  return null;
}

/** Turn Firestore values (Timestamp, etc.) into plain JSON-safe data. */
export function firestoreToJson(value: unknown): unknown {
  if (value == null) return value;
  if (typeof value !== 'object') return value;
  const asTs = asDate(value);
  if (asTs && !(value instanceof Date) && !Array.isArray(value)) {
    // Prefer Timestamp conversion when object looks like one.
    const o = value as { toDate?: unknown; seconds?: unknown };
    if (typeof o.toDate === 'function' || 'seconds' in o || '_seconds' in o) {
      return asTs.toISOString();
    }
  }
  if (Array.isArray(value)) return value.map(firestoreToJson);
  if (value instanceof Date) return value.toISOString();
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
    out[k] = firestoreToJson(v);
  }
  return out;
}

export function parseFirestoreDate(raw: unknown): Date | null {
  return asDate(raw);
}
