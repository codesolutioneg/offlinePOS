/// Tax upload: migrate Dishflow ETA receipts into Postgres and submit new ones.
import { Prisma, type PrismaClient } from '@prisma/client';
import { createHash, randomBytes } from 'node:crypto';
import { FieldValue, type DocumentData, type QueryDocumentSnapshot } from 'firebase-admin/firestore';

import {
  firestoreToJson,
  getFirestore,
  parseFirestoreDate,
  taxFirebaseReady,
  type TaxFirebaseConfig,
} from './firebase.js';
import {
  submitReceipt,
  type EtaCompany,
  type EtaIntegration,
} from './eta.js';

export const NASR_CONNECTION_ID = 'yFsBtvlradoAkKSascZ3';

export type TaxEnv = TaxFirebaseConfig & {
  /** Firebase Hosting origin for etaProxy fallback, e.g. https://pos-test-70970.web.app */
  etaProxyBase: string;
  defaultConnectionId: string;
};

function newId(): string {
  return createHash('sha256').update(randomBytes(24)).digest('hex').slice(0, 24);
}

function saleAmount(sale: Record<string, unknown>): number {
  for (const k of ['totalAmount', 'total', 'amount', 'grandTotal']) {
    const n = Number(sale[k]);
    if (Number.isFinite(n)) return n;
  }
  return 0;
}

function asIntegrations(raw: unknown): EtaIntegration[] {
  if (!Array.isArray(raw)) return [];
  return raw
    .filter((x): x is Record<string, unknown> => Boolean(x) && typeof x === 'object')
    .map((m) => ({
      id: String(m.id ?? newId()),
      name: String(m.name ?? ''),
      clientId: String(m.clientId ?? ''),
      clientSecret: String(m.clientSecret ?? ''),
      serialNumber: String(m.serialNumber ?? ''),
      isDefault: m.isDefault === true,
      branchCode: String(m.branchCode ?? '0'),
      addressCountry: String(m.addressCountry ?? 'EG'),
      addressGovernate: String(m.addressGovernate ?? ''),
      addressRegionCity: String(m.addressRegionCity ?? ''),
      addressStreet: String(m.addressStreet ?? ''),
      addressBuildingNumber: String(m.addressBuildingNumber ?? ''),
      orderTypes: Array.isArray(m.orderTypes)
        ? m.orderTypes.map((t) => String(t))
        : [],
    }));
}

function ymdUtc(d: Date): string {
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${String(d.getUTCDate()).padStart(2, '0')}`;
}

/** Inclusive business-date keys for [from, to). Null = no date filter (all). */
function businessDateKeys(from?: Date, to?: Date): string[] | null {
  if (!from && !to) return null;
  const start = from
    ? Date.UTC(from.getUTCFullYear(), from.getUTCMonth(), from.getUTCDate())
    : Date.UTC(1970, 0, 1);
  const endExclusive = to
    ? Date.UTC(to.getUTCFullYear(), to.getUTCMonth(), to.getUTCDate())
    : Date.UTC(2100, 0, 1);
  const keys: string[] = [];
  for (let t = start; t < endExclusive; t += 86_400_000) {
    keys.push(ymdUtc(new Date(t)));
    if (keys.length > 366) break;
  }
  return keys;
}

export class TaxService {
  constructor(
    private readonly db: PrismaClient,
    private readonly env: TaxEnv,
  ) {}

  ready(): boolean {
    return taxFirebaseReady(this.env);
  }

  private companyFromRow(row: {
    rin: string;
    companyTradeName: string;
    activityCode: string;
    useSandbox: boolean;
    integrationsJson: Prisma.JsonValue;
  }): EtaCompany {
    return {
      rin: row.rin,
      companyTradeName: row.companyTradeName,
      activityCode: row.activityCode || '5610',
      useSandbox: row.useSandbox,
      integrations: asIntegrations(row.integrationsJson),
    };
  }

  async syncEtaSettings(shopId: string): Promise<EtaCompany> {
    const fs = getFirestore(this.env);
    const snap = await fs.collection('settings').doc('eta_integration').get();
    if (!snap.exists) throw new Error('settings/eta_integration not found in Firebase');
    const d = snap.data() ?? {};
    const integrations = asIntegrations(d.integrations);
    const company: EtaCompany = {
      rin: String(d.rin ?? ''),
      companyTradeName: String(d.companyTradeName ?? ''),
      activityCode: String(d.activityCode ?? '5610') || '5610',
      useSandbox: d.useSandbox === true,
      integrations,
    };
    await this.db.taxEtaSettings.upsert({
      where: { shopId },
      create: {
        shopId,
        firebaseProjectId: this.env.projectId,
        connectionId: this.env.defaultConnectionId || NASR_CONNECTION_ID,
        rin: company.rin,
        companyTradeName: company.companyTradeName,
        activityCode: company.activityCode,
        useSandbox: company.useSandbox,
        integrationsJson: integrations as unknown as Prisma.InputJsonValue,
      },
      update: {
        firebaseProjectId: this.env.projectId,
        rin: company.rin,
        companyTradeName: company.companyTradeName,
        activityCode: company.activityCode,
        useSandbox: company.useSandbox,
        integrationsJson: integrations as unknown as Prisma.InputJsonValue,
      },
    });
    return company;
  }

  async getSettingsPublic(shopId: string) {
    const row = await this.db.taxEtaSettings.findUnique({ where: { shopId } });
    if (!row) return null;
    const connectionId = row.connectionId || this.env.defaultConnectionId || NASR_CONNECTION_ID;
    const integrations = asIntegrations(row.integrationsJson).map((i) => ({
      id: i.id,
      name: i.name,
      serialNumber: i.serialNumber,
      isDefault: i.isDefault === true,
      branchCode: i.branchCode ?? '0',
      addressCountry: i.addressCountry ?? 'EG',
      addressGovernate: i.addressGovernate ?? '',
      addressRegionCity: i.addressRegionCity ?? '',
      addressStreet: i.addressStreet ?? '',
      addressBuildingNumber: i.addressBuildingNumber ?? '',
      orderTypes: i.orderTypes ?? [],
      has_client_id: Boolean(i.clientId),
      has_client_secret: Boolean(i.clientSecret),
      // secrets stay on the server — blank fields on save keep existing
      clientId: '',
      clientSecret: '',
    }));
    return {
      firebase_project_id: row.firebaseProjectId,
      connection_id: connectionId,
      connection_name:
        connectionId === NASR_CONNECTION_ID ? 'Balkans Nasr City' : connectionId,
      rin: row.rin,
      company_trade_name: row.companyTradeName,
      activity_code: row.activityCode,
      use_sandbox: row.useSandbox,
      integrations,
      updated_at: row.updatedAt.toISOString(),
    };
  }

  /**
   * Save ETA company + POS integrations (Dishflow-shaped). Empty clientId/secret
   * on an existing integration keeps the stored secret.
   */
  async saveSettings(
    shopId: string,
    body: {
      connection_id?: string;
      rin?: string;
      company_trade_name?: string;
      activity_code?: string;
      use_sandbox?: boolean;
      integrations?: unknown;
    },
  ) {
    const existing = await this.db.taxEtaSettings.findUnique({ where: { shopId } });
    const prev = asIntegrations(existing?.integrationsJson ?? []);
    const prevById = new Map(prev.map((i) => [i.id, i]));

    const incoming = Array.isArray(body.integrations)
      ? asIntegrations(body.integrations)
      : prev;

    const integrations: EtaIntegration[] = incoming.map((i) => {
      const old = prevById.get(i.id);
      return {
        ...i,
        id: i.id || newId(),
        clientId: i.clientId.trim() || old?.clientId || '',
        clientSecret: i.clientSecret.trim() || old?.clientSecret || '',
        serialNumber: i.serialNumber.trim() || old?.serialNumber || '',
        name: i.name.trim() || old?.name || '',
        branchCode: i.branchCode || old?.branchCode || '0',
        addressCountry: i.addressCountry || old?.addressCountry || 'EG',
        addressGovernate: i.addressGovernate || old?.addressGovernate || '',
        addressRegionCity: i.addressRegionCity || old?.addressRegionCity || '',
        addressStreet: i.addressStreet || old?.addressStreet || '',
        addressBuildingNumber:
          i.addressBuildingNumber || old?.addressBuildingNumber || '',
        orderTypes: i.orderTypes?.length ? i.orderTypes : old?.orderTypes ?? [],
        isDefault: i.isDefault === true,
      };
    });

    if (integrations.length && !integrations.some((i) => i.isDefault)) {
      integrations[0]!.isDefault = true;
    }

    const connectionId =
      (body.connection_id ??
        existing?.connectionId ??
        this.env.defaultConnectionId ??
        NASR_CONNECTION_ID)
        .trim() || NASR_CONNECTION_ID;

    await this.db.taxEtaSettings.upsert({
      where: { shopId },
      create: {
        shopId,
        firebaseProjectId: this.env.projectId || existing?.firebaseProjectId || '',
        connectionId,
        rin: (body.rin ?? existing?.rin ?? '').trim(),
        companyTradeName: (body.company_trade_name ?? existing?.companyTradeName ?? '').trim(),
        activityCode: (body.activity_code ?? existing?.activityCode ?? '5610').trim() || '5610',
        useSandbox: body.use_sandbox ?? existing?.useSandbox ?? false,
        integrationsJson: integrations as unknown as Prisma.InputJsonValue,
      },
      update: {
        connectionId,
        rin: body.rin !== undefined ? body.rin.trim() : undefined,
        companyTradeName:
          body.company_trade_name !== undefined
            ? body.company_trade_name.trim()
            : undefined,
        activityCode:
          body.activity_code !== undefined
            ? body.activity_code.trim() || '5610'
            : undefined,
        useSandbox: body.use_sandbox,
        integrationsJson: integrations as unknown as Prisma.InputJsonValue,
      },
    });
    return this.getSettingsPublic(shopId);
  }

  /** Pull every etaSubmitted sale for a connection into Postgres. Idempotent. */
  async migrateSubmitted(
    shopId: string,
    connectionId: string,
  ): Promise<{ scanned: number; inserted: number; updated: number }> {
    await this.syncEtaSettings(shopId);
    const fs = getFirestore(this.env);
    let scanned = 0;
    let inserted = 0;
    let updated = 0;
    let lastDoc: QueryDocumentSnapshot | undefined;

    for (;;) {
      let q = fs
        .collection('sales')
        .where('etaSubmitted', '==', true)
        .where('odooConnectionId', '==', connectionId)
        .orderBy('__name__')
        .limit(200);
      if (lastDoc) q = q.startAfter(lastDoc);
      const page = await q.get();
      if (page.empty) break;

      for (const doc of page.docs) {
        scanned++;
        const raw = doc.data();
        const payload = firestoreToJson(raw) as Record<string, unknown>;
        const submittedAt =
          parseFirestoreDate(raw.etaSubmittedAt) ??
          parseFirestoreDate(raw.timestamp) ??
          new Date();
        const data = {
          shopId,
          connectionId,
          branchName: String(raw.odooConnectionName ?? raw.branchName ?? ''),
          orderNumber: String(raw.orderNumber ?? ''),
          sessionId: String(raw.sessionId ?? ''),
          businessDateKey: String(raw.businessDateKey ?? ''),
          paymentMethod: String(raw.paymentMethod ?? ''),
          amount: saleAmount(raw as Record<string, unknown>),
          status: 'submitted' as const,
          etaUuid: raw.etaUuid != null ? String(raw.etaUuid) : null,
          etaLongId: raw.etaLongId != null ? String(raw.etaLongId) : null,
          etaSubmissionId: raw.etaSubmissionId != null ? String(raw.etaSubmissionId) : null,
          etaSubmittedAt: submittedAt,
          error: null as string | null,
          payload: payload as Prisma.InputJsonValue,
        };
        const existing = await this.db.taxInvoice.findUnique({
          where: { firebaseDocId: doc.id },
        });
        if (existing) {
          await this.db.taxInvoice.update({
            where: { id: existing.id },
            data,
          });
          updated++;
        } else {
          await this.db.taxInvoice.create({
            data: { id: newId(), firebaseDocId: doc.id, ...data },
          });
          inserted++;
        }
      }
      lastDoc = page.docs[page.docs.length - 1];
      if (page.size < 200) break;
    }
    return { scanned, inserted, updated };
  }

  async summary(
    shopId: string,
    opts: {
      connectionId?: string;
      from?: Date;
      to?: Date;
      sessionId?: string;
      paymentMethod?: string;
      status?: string;
    },
  ) {
    const where = this.where(shopId, opts);
    const [count, agg, byPayment, byStatus] = await Promise.all([
      this.db.taxInvoice.count({ where }),
      this.db.taxInvoice.aggregate({ where, _sum: { amount: true } }),
      this.db.taxInvoice.groupBy({
        by: ['paymentMethod'],
        where,
        _count: { _all: true },
        _sum: { amount: true },
      }),
      this.db.taxInvoice.groupBy({
        by: ['status'],
        where,
        _count: { _all: true },
      }),
    ]);
    const sessions = await this.db.taxInvoice.findMany({
      where,
      distinct: ['sessionId'],
      select: { sessionId: true },
    });
    const compare = await this.periodCompare(shopId, opts);
    return {
      count,
      total_amount: agg._sum.amount ?? 0,
      sessions: sessions.map((s) => s.sessionId).filter(Boolean).length,
      by_payment: byPayment.map((r) => ({
        payment_method: r.paymentMethod,
        count: r._count._all,
        amount: r._sum.amount ?? 0,
      })),
      by_status: byStatus.map((r) => ({
        status: r.status,
        count: r._count._all,
      })),
      ...compare,
    };
  }

  /**
   * Gross sales vs ETA-submitted for the period (business dates).
   * Prefers Firebase live totals; falls back to Postgres tax_invoices.
   */
  async periodCompare(
    shopId: string,
    opts: {
      connectionId?: string;
      from?: Date;
      to?: Date;
      sessionId?: string;
      paymentMethod?: string;
    },
  ) {
    const connectionId =
      (opts.connectionId ?? NASR_CONNECTION_ID).trim() || NASR_CONNECTION_ID;
    const keys = businessDateKeys(opts.from, opts.to);

    let grossCount = 0;
    let grossAmount = 0;
    let submittedCount = 0;
    let submittedAmount = 0;
    let source: 'firebase' | 'db' = 'db';

    if (this.ready()) {
      try {
        const fs = getFirestore(this.env);
        const sales = keys
          ? await this.loadSalesForDateKeys(fs, connectionId, keys)
          : await this.loadRecentSales(fs, connectionId, 3000);

        for (const raw of sales) {
          if (opts.sessionId) {
            const sid = String(raw.sessionId ?? '').trim() || '—';
            if (sid !== opts.sessionId) continue;
          }
          if (opts.paymentMethod) {
            if (String(raw.paymentMethod ?? '') !== opts.paymentMethod) continue;
          }
          const amt = saleAmount(raw);
          grossCount += 1;
          grossAmount += amt;
          if (raw.etaSubmitted === true) {
            submittedCount += 1;
            submittedAmount += amt;
          }
        }
        source = 'firebase';
      } catch {
        source = 'db';
      }
    }

    if (source === 'db') {
      const base: Prisma.TaxInvoiceWhereInput = {
        shopId,
        connectionId,
        ...(opts.sessionId ? { sessionId: opts.sessionId } : {}),
        ...(opts.paymentMethod ? { paymentMethod: opts.paymentMethod } : {}),
        ...(keys ? { businessDateKey: { in: keys } } : {}),
      };
      const [grossAgg, submittedAgg, grossN, submittedN] = await Promise.all([
        this.db.taxInvoice.aggregate({ where: base, _sum: { amount: true } }),
        this.db.taxInvoice.aggregate({
          where: { ...base, status: 'submitted' },
          _sum: { amount: true },
        }),
        this.db.taxInvoice.count({ where: base }),
        this.db.taxInvoice.count({ where: { ...base, status: 'submitted' } }),
      ]);
      grossCount = grossN;
      grossAmount = grossAgg._sum.amount ?? 0;
      submittedCount = submittedN;
      submittedAmount = submittedAgg._sum.amount ?? 0;
    }

    return {
      compare_source: source,
      submitted_count: submittedCount,
      submitted_amount: submittedAmount,
      gross_count: grossCount,
      gross_amount: grossAmount,
      difference_count: Math.max(0, grossCount - submittedCount),
      difference_amount: Math.max(0, grossAmount - submittedAmount),
    };
  }

  private async loadSalesForDateKeys(
    fs: ReturnType<typeof getFirestore>,
    connectionId: string,
    keys: string[],
  ): Promise<Record<string, unknown>[]> {
    const out: Record<string, unknown>[] = [];
    for (const key of keys) {
      let snap;
      try {
        snap = await fs
          .collection('sales')
          .where('odooConnectionId', '==', connectionId)
          .where('businessDateKey', '==', key)
          .get();
      } catch {
        snap = await fs
          .collection('sales')
          .where('odooConnectionId', '==', connectionId)
          .limit(2000)
          .get();
        for (const doc of snap.docs) {
          const raw = doc.data() as Record<string, unknown>;
          if (String(raw.businessDateKey ?? '') === key) {
            out.push(raw);
          }
        }
        continue;
      }
      for (const doc of snap.docs) {
        out.push(doc.data() as Record<string, unknown>);
      }
    }
    return out;
  }

  private async loadRecentSales(
    fs: ReturnType<typeof getFirestore>,
    connectionId: string,
    limit: number,
  ): Promise<Record<string, unknown>[]> {
    let snap;
    try {
      snap = await fs
        .collection('sales')
        .where('odooConnectionId', '==', connectionId)
        .orderBy('timestamp', 'desc')
        .limit(limit)
        .get();
    } catch {
      snap = await fs
        .collection('sales')
        .where('odooConnectionId', '==', connectionId)
        .limit(limit)
        .get();
    }
    return snap.docs.map((d) => d.data() as Record<string, unknown>);
  }

  async list(
    shopId: string,
    opts: {
      connectionId?: string;
      from?: Date;
      to?: Date;
      sessionId?: string;
      paymentMethod?: string;
      status?: string;
      limit?: number;
      offset?: number;
    },
  ) {
    const where = this.where(shopId, opts);
    const take = Math.min(Math.max(opts.limit ?? 100, 1), 500);
    const skip = Math.max(opts.offset ?? 0, 0);
    const [total, rows] = await Promise.all([
      this.db.taxInvoice.count({ where }),
      this.db.taxInvoice.findMany({
        where,
        orderBy: [{ etaSubmittedAt: 'desc' }, { createdAt: 'desc' }],
        take,
        skip,
      }),
    ]);
    return {
      total,
      invoices: rows.map((r) => ({
        id: r.id,
        firebase_doc_id: r.firebaseDocId,
        connection_id: r.connectionId,
        branch_name: r.branchName,
        order_number: r.orderNumber,
        session_id: r.sessionId,
        business_date_key: r.businessDateKey,
        payment_method: r.paymentMethod,
        amount: r.amount,
        status: r.status,
        eta_uuid: r.etaUuid,
        eta_long_id: r.etaLongId,
        eta_submission_id: r.etaSubmissionId,
        eta_submitted_at: r.etaSubmittedAt?.toISOString() ?? null,
        error: r.error,
        created_at: r.createdAt.toISOString(),
      })),
    };
  }

  /**
   * Pull unsubmitted Firebase sales into Postgres as status=pending.
   * After this, the Upload tab works entirely from our DB.
   */
  async syncPending(
    shopId: string,
    connectionId: string,
    opts?: { limit?: number },
  ): Promise<{ scanned: number; inserted: number; updated: number }> {
    await this.syncEtaSettings(shopId);
    const fs = getFirestore(this.env);
    const limit = Math.min(Math.max(opts?.limit ?? 500, 1), 1000);
    let snap;
    try {
      snap = await fs
        .collection('sales')
        .where('odooConnectionId', '==', connectionId)
        .orderBy('timestamp', 'desc')
        .limit(limit)
        .get();
    } catch {
      snap = await fs
        .collection('sales')
        .where('odooConnectionId', '==', connectionId)
        .limit(limit)
        .get();
    }

    let scanned = 0;
    let inserted = 0;
    let updated = 0;
    for (const doc of snap.docs) {
      const raw = doc.data();
      if (raw.etaSubmitted === true) continue;
      scanned++;
      const payload = firestoreToJson(raw) as Record<string, unknown>;
      const existing = await this.db.taxInvoice.findUnique({
        where: { firebaseDocId: doc.id },
      });
      if (existing?.status === 'submitted') continue;
      const data = {
        shopId,
        connectionId,
        branchName: String(raw.odooConnectionName ?? raw.branchName ?? ''),
        orderNumber: String(raw.orderNumber ?? ''),
        sessionId: String(raw.sessionId ?? ''),
        businessDateKey: String(raw.businessDateKey ?? ''),
        paymentMethod: String(raw.paymentMethod ?? ''),
        amount: saleAmount(raw as Record<string, unknown>),
        status: existing?.status === 'failed' ? 'failed' : 'pending',
        payload: payload as Prisma.InputJsonValue,
        error: existing?.status === 'failed' ? existing.error : null,
      };
      if (existing) {
        await this.db.taxInvoice.update({ where: { id: existing.id }, data });
        updated++;
      } else {
        await this.db.taxInvoice.create({
          data: { id: newId(), firebaseDocId: doc.id, ...data },
        });
        inserted++;
      }
    }
    return { scanned, inserted, updated };
  }

  /** Branches/connections known for this shop (Nasr first, then others from data). */
  async listConnections(shopId: string): Promise<
    { connection_id: string; name: string; pending: number; submitted: number }[]
  > {
    const settings = await this.db.taxEtaSettings.findUnique({ where: { shopId } });
    const defaultId =
      settings?.connectionId || this.env.defaultConnectionId || NASR_CONNECTION_ID;
    const grouped = await this.db.taxInvoice.groupBy({
      by: ['connectionId', 'status'],
      where: { shopId },
      _count: { _all: true },
    });
    const names = await this.db.taxInvoice.findMany({
      where: { shopId },
      distinct: ['connectionId'],
      select: { connectionId: true, branchName: true },
    });
    const nameOf = new Map(names.map((n) => [n.connectionId, n.branchName || n.connectionId]));
    const map = new Map<
      string,
      { connection_id: string; name: string; pending: number; submitted: number }
    >();
    const ensure = (id: string) => {
      if (!map.has(id)) {
        map.set(id, {
          connection_id: id,
          name:
            id === NASR_CONNECTION_ID
              ? 'Balkans Nasr City'
              : nameOf.get(id) || id,
          pending: 0,
          submitted: 0,
        });
      }
      return map.get(id)!;
    };
    ensure(defaultId);
    for (const g of grouped) {
      const row = ensure(g.connectionId);
      if (g.status === 'pending' || g.status === 'failed') row.pending += g._count._all;
      if (g.status === 'submitted') row.submitted += g._count._all;
    }
    const list = [...map.values()];
    list.sort((a, b) => {
      if (a.connection_id === defaultId) return -1;
      if (b.connection_id === defaultId) return 1;
      return a.name.localeCompare(b.name);
    });
    return list;
  }

  /** Pending/failed invoices already in our DB (upload wizard source). */
  async listPendingFromDb(
    shopId: string,
    opts: {
      connectionId?: string;
      sessionId?: string;
      paymentMethod?: string;
      limit?: number;
    },
  ) {
    const take = Math.min(Math.max(opts.limit ?? 500, 1), 1000);
    const rows = await this.db.taxInvoice.findMany({
      where: {
        shopId,
        status: { in: ['pending', 'failed'] },
        ...(opts.connectionId ? { connectionId: opts.connectionId } : {}),
        ...(opts.sessionId ? { sessionId: opts.sessionId } : {}),
        ...(opts.paymentMethod ? { paymentMethod: opts.paymentMethod } : {}),
      },
      orderBy: [{ createdAt: 'desc' }],
      take,
    });
    const payments = new Map<string, { count: number; amount: number }>();
    for (const r of rows) {
      const key = r.paymentMethod || '—';
      const cur = payments.get(key) ?? { count: 0, amount: 0 };
      cur.count += 1;
      cur.amount += r.amount;
      payments.set(key, cur);
    }
    return {
      pending: rows.map((r) => ({
        id: r.id,
        firebase_doc_id: r.firebaseDocId,
        order_number: r.orderNumber,
        session_id: r.sessionId,
        business_date_key: r.businessDateKey,
        payment_method: r.paymentMethod,
        amount: r.amount,
        status: r.status,
        error: r.error,
        timestamp:
          typeof (r.payload as Record<string, unknown> | null)?.timestamp === 'string'
            ? String((r.payload as Record<string, unknown>).timestamp)
            : r.createdAt.toISOString(),
      })),
      by_payment: [...payments.entries()].map(([payment_method, v]) => ({
        payment_method,
        count: v.count,
        amount: v.amount,
      })),
    };
  }

  /** Submit selected DB invoice rows to ETA (payload already on the server). */
  async submitBatch(
    shopId: string,
    opts: {
      connectionId: string;
      invoiceIds: string[];
      createdBy: string;
    },
  ): Promise<{
    batch_id: string;
    accepted: number;
    rejected: number;
    results: {
      id: string;
      firebase_doc_id: string | null;
      success: boolean;
      uuid?: string;
      long_id?: string;
      error?: string;
    }[];
  }> {
    let settings = await this.db.taxEtaSettings.findUnique({ where: { shopId } });
    if (!settings) {
      await this.syncEtaSettings(shopId);
      settings = await this.db.taxEtaSettings.findUniqueOrThrow({ where: { shopId } });
    }
    const company = this.companyFromRow(settings);
    const batch = await this.db.taxUploadBatch.create({
      data: {
        id: newId(),
        shopId,
        connectionId: opts.connectionId,
        createdBy: opts.createdBy,
        status: 'running',
        total: opts.invoiceIds.length,
      },
    });

    let accepted = 0;
    let rejected = 0;
    const results: {
      id: string;
      firebase_doc_id: string | null;
      success: boolean;
      uuid?: string;
      long_id?: string;
      error?: string;
    }[] = [];

    for (const invoiceId of opts.invoiceIds) {
      const row = await this.db.taxInvoice.findFirst({
        where: { id: invoiceId, shopId },
      });
      if (!row) {
        rejected++;
        results.push({
          id: invoiceId,
          firebase_doc_id: null,
          success: false,
          error: 'invoice not found',
        });
        continue;
      }
      if (row.status === 'submitted') {
        accepted++;
        results.push({
          id: row.id,
          firebase_doc_id: row.firebaseDocId,
          success: true,
          uuid: row.etaUuid ?? undefined,
          long_id: row.etaLongId ?? undefined,
        });
        continue;
      }

      const sale = (row.payload ?? {}) as Record<string, unknown>;
      const result = await submitReceipt({
        sale,
        company,
        proxyBase: this.env.etaProxyBase || undefined,
      });

      if (result.success) {
        const now = new Date();
        sale.etaSubmitted = true;
        sale.etaUuid = result.uuid ?? null;
        sale.etaLongId = result.longId ?? null;
        sale.etaSubmissionId = result.submissionId ?? null;
        sale.etaSubmittedAt = now.toISOString();
        await this.db.taxInvoice.update({
          where: { id: row.id },
          data: {
            status: 'submitted',
            etaUuid: result.uuid ?? null,
            etaLongId: result.longId ?? null,
            etaSubmissionId: result.submissionId ?? null,
            etaSubmittedAt: now,
            error: null,
            payload: sale as Prisma.InputJsonValue,
            batchId: batch.id,
          },
        });
        // Best-effort mirror to Firebase so Dishflow does not re-upload.
        if (row.firebaseDocId) {
          try {
            const fs = getFirestore(this.env);
            await fs.collection('sales').doc(row.firebaseDocId).set(
              {
                etaSubmitted: true,
                etaUuid: result.uuid ?? null,
                etaLongId: result.longId ?? null,
                etaSubmissionId: result.submissionId ?? null,
                etaSubmittedAt: FieldValue.serverTimestamp(),
              },
              { merge: true },
            );
          } catch {
            /* DB is source of truth for this site */
          }
        }
        accepted++;
        results.push({
          id: row.id,
          firebase_doc_id: row.firebaseDocId,
          success: true,
          uuid: result.uuid,
          long_id: result.longId,
        });
      } else {
        await this.db.taxInvoice.update({
          where: { id: row.id },
          data: {
            status: 'failed',
            error: result.error ?? 'failed',
            batchId: batch.id,
          },
        });
        rejected++;
        results.push({
          id: row.id,
          firebase_doc_id: row.firebaseDocId,
          success: false,
          uuid: result.uuid,
          error: result.error,
        });
      }
    }

    await this.db.taxUploadBatch.update({
      where: { id: batch.id },
      data: {
        status: rejected && !accepted ? 'failed' : 'done',
        accepted,
        rejected,
        finishedAt: new Date(),
      },
    });

    return { batch_id: batch.id, accepted, rejected, results };
  }

  private async upsertSubmitted(
    shopId: string,
    connectionId: string,
    docId: string,
    raw: DocumentData,
    payload: Record<string, unknown>,
    batchId: string,
  ) {
    const submittedAt =
      parseFirestoreDate(raw.etaSubmittedAt) ??
      parseFirestoreDate(raw.timestamp) ??
      new Date();
    await this.db.taxInvoice.upsert({
      where: { firebaseDocId: docId },
      create: {
        id: newId(),
        shopId,
        connectionId,
        branchName: String(raw.odooConnectionName ?? ''),
        firebaseDocId: docId,
        orderNumber: String(raw.orderNumber ?? ''),
        sessionId: String(raw.sessionId ?? ''),
        businessDateKey: String(raw.businessDateKey ?? ''),
        paymentMethod: String(raw.paymentMethod ?? ''),
        amount: saleAmount(raw as Record<string, unknown>),
        status: 'submitted',
        etaUuid: raw.etaUuid != null ? String(raw.etaUuid) : null,
        etaLongId: raw.etaLongId != null ? String(raw.etaLongId) : null,
        etaSubmissionId: raw.etaSubmissionId != null ? String(raw.etaSubmissionId) : null,
        etaSubmittedAt: submittedAt,
        payload: payload as Prisma.InputJsonValue,
        batchId,
      },
      update: {
        status: 'submitted',
        etaUuid: raw.etaUuid != null ? String(raw.etaUuid) : null,
        etaLongId: raw.etaLongId != null ? String(raw.etaLongId) : null,
        etaSubmissionId: raw.etaSubmissionId != null ? String(raw.etaSubmissionId) : null,
        etaSubmittedAt: submittedAt,
        error: null,
        payload: payload as Prisma.InputJsonValue,
        batchId,
      },
    });
  }

  private where(
    shopId: string,
    opts: {
      connectionId?: string;
      from?: Date;
      to?: Date;
      sessionId?: string;
      paymentMethod?: string;
      status?: string;
    },
  ): Prisma.TaxInvoiceWhereInput {
    const where: Prisma.TaxInvoiceWhereInput = { shopId };
    if (opts.connectionId) where.connectionId = opts.connectionId;
    if (opts.sessionId) where.sessionId = opts.sessionId;
    if (opts.paymentMethod) where.paymentMethod = opts.paymentMethod;
    if (opts.status) where.status = opts.status;
    if (opts.from || opts.to) {
      where.etaSubmittedAt = {};
      if (opts.from) where.etaSubmittedAt.gte = opts.from;
      if (opts.to) where.etaSubmittedAt.lt = opts.to;
    }
    return where;
  }
}

