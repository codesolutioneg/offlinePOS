import type { Role, User } from './repo.js';

/// What a user may open on the reports site, beyond the sales every user sees.
///
/// The same names are read by the web app (lib/web_reports/report_access.dart),
/// which hides the reports a user lacks; this side withholds the data behind
/// them, so hiding a tile is not the only thing standing in the way.
export const CAPABILITIES = [
  /// Cost vs sales, menu engineering, margins: what a dish costs the shop.
  'costs',
  /// Cancelled, voided and refunded activity, from the tills' audit trails.
  'audit',
  /// Hours worked, from the clock-ins.
  'staff',
  /// Expenses and cash movements on the drawer.
  'expenses',
  /// The back-office layouts (the RM report folders).
  'backoffice',
  /// The Flash reports.
  'flash',
] as const;

export type Capability = (typeof CAPABILITIES)[number];

export const ROLES: Role[] = ['owner', 'manager', 'accountant'];

export const DEFAULT_CAPABILITIES: Record<Role, Capability[]> = {
  owner: [...CAPABILITIES],
  manager: [...CAPABILITIES],
  accountant: ['expenses', 'backoffice', 'flash'],
};

export const isCapability = (c: string): c is Capability =>
  (CAPABILITIES as readonly string[]).includes(c);

/// An owner can do everything, whatever the row says.
export function capabilitiesOf(user: Pick<User, 'role' | 'capabilities'>): Capability[] {
  if (user.role === 'owner') return [...CAPABILITIES];
  return user.capabilities.filter(isCapability);
}

/// The branches a user may read: null for every branch of the shop.
export function branchScope(user: Pick<User, 'role' | 'allBranches' | 'branchIds'>): string[] | null {
  if (user.role === 'owner' || user.allBranches) return null;
  return user.branchIds;
}

/// The record kinds a user may be sent.
export function readableKinds(user: Pick<User, 'role' | 'capabilities'>): Set<string> {
  const caps = new Set(capabilitiesOf(user));
  return new Set([
    'order',
    'shift',
    'categories',
    'staff',
    'tenders',
    'drivers',
    'shop',
    ...(caps.has('costs') ? ['costs'] : []),
    ...(caps.has('audit') ? ['audit'] : []),
    ...(caps.has('staff') ? ['attendance'] : []),
  ]);
}

/// What the tills send, by kind. Anything else is refused.
export const RECORD_KINDS = new Set([
  'order',
  'shift',
  'attendance',
  'audit',
  'categories',
  'costs',
  'staff',
  'tenders',
  'drivers',
  'shop',
]);

/// Kinds with one record per branch, replaced whole each time.
export const SNAPSHOT_KINDS = new Set(['categories', 'costs', 'staff', 'tenders', 'drivers', 'shop']);
