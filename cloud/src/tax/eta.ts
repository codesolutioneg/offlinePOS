/// Egypt Tax Authority eReceipt helpers — ported from Dishflow EtaService.
import { createHash } from 'node:crypto';

export type EtaIntegration = {
  id: string;
  name: string;
  clientId: string;
  clientSecret: string;
  serialNumber: string;
  isDefault?: boolean;
  branchCode?: string;
  addressCountry?: string;
  addressGovernate?: string;
  addressRegionCity?: string;
  addressStreet?: string;
  addressBuildingNumber?: string;
  orderTypes?: string[];
};

export type EtaCompany = {
  rin: string;
  companyTradeName: string;
  activityCode: string;
  useSandbox: boolean;
  integrations: EtaIntegration[];
};

export type EtaSubmitResult = {
  success: boolean;
  submissionId?: string;
  uuid?: string;
  longId?: string;
  acceptedDocuments: number;
  rejectedDocuments: number;
  error?: string;
};

const PROD_TOKEN = 'https://id.eta.gov.eg/connect/token';
const SANDBOX_TOKEN = 'https://id.preprod.eta.gov.eg/connect/token';
const PROD_API = 'https://api.invoicing.eta.gov.eg';
const SANDBOX_API = 'https://api.preprod.eta.gov.eg';

type TokenCache = { token: string; expiry: Date; forId: string };
let tokenCache: TokenCache | null = null;

function r2(v: number): number {
  return Math.round(v * 100) / 100;
}
function r5(v: number): number {
  return Math.round(v * 100000) / 100000;
}

function mapPaymentMethod(label: string): string {
  const l = label.toLowerCase();
  if (l.includes('كاش') || l.includes('نقد') || l.includes('cash')) return 'C';
  return 'C';
}

/** ETA canonical serialization then SHA-256 hex (uuid of the receipt). */
export function computeUuid(receipt: Record<string, unknown>): string {
  const canon = canonicalize(receipt, '');
  return createHash('sha256').update(canon, 'utf8').digest('hex');
}

function canonicalize(token: unknown, name: string): string {
  if (Array.isArray(token)) {
    let sb = '';
    for (const child of token) {
      sb += `"${name.toUpperCase()}"`;
      sb += canonicalize(child, name);
    }
    return sb;
  }
  if (token !== null && typeof token === 'object') {
    let sb = '';
    for (const [k, v] of Object.entries(token as Record<string, unknown>)) {
      if (k.toLowerCase() === 'signatures') continue;
      sb += `"${k.toUpperCase()}"`;
      sb += canonicalize(v, k);
    }
    return sb;
  }
  if (typeof token === 'number') {
    if (Number.isFinite(token) && token % 1 === 0) return `"${token}"`;
    return `"${token}"`;
  }
  return `"${String(token)}"`;
}

export function pickIntegration(company: EtaCompany, orderType: string): EtaIntegration | null {
  const list = company.integrations;
  if (!list.length) return null;
  const t = orderType.trim().toLowerCase();
  if (t) {
    for (const i of list) {
      for (const mapped of i.orderTypes ?? []) {
        if (mapped.trim().toLowerCase() === t) return i;
      }
    }
  }
  return list.find((i) => i.isDefault) ?? list[0]!;
}

export function buildReceiptJson(opts: {
  sale: Record<string, unknown>;
  integration: EtaIntegration;
  rin: string;
  companyTradeName: string;
  activityCode: string;
  previousUUID?: string;
}): Record<string, unknown> {
  const { sale, integration, rin, companyTradeName, activityCode, previousUUID } = opts;

  const rawOrderNum = String(sale.orderNumber ?? '').trim();
  const rawId = String(sale.odooOrderId ?? '').trim();
  let receiptNumber: string;
  if (rawOrderNum) {
    const parts = rawOrderNum.split('-');
    receiptNumber = parts.length >= 2 ? parts[1]! : rawOrderNum;
  } else if (rawId && !rawId.startsWith('pending_')) {
    receiptNumber = rawId;
  } else {
    const local = String(sale.localOrderId ?? '').trim();
    receiptNumber = local ? `POS-${local}` : `POS-${Date.now()}`;
  }

  let saleTime = new Date();
  const rawTs = sale.timestamp;
  if (typeof rawTs === 'string') {
    const d = new Date(rawTs);
    if (!Number.isNaN(d.getTime())) saleTime = d;
  } else if (rawTs instanceof Date) {
    saleTime = rawTs;
  }
  const cutoff = new Date(Date.now() - 5 * 60 * 1000);
  const dtIssued = saleTime.getTime() > cutoff.getTime() ? cutoff : saleTime;
  const dtStr = dtIssued.toISOString().replace(/\.\d+Z$/, 'Z');

  const rawItems = Array.isArray(sale.items) ? sale.items : [];
  const taxRate = 14;
  const templateToVariant: Record<string, string> = {};
  const orderLinesRaw = sale.orderLinesRaw;
  if (Array.isArray(orderLinesRaw)) {
    for (const line of orderLinesRaw) {
      if (line && typeof line === 'object') {
        const m = line as Record<string, unknown>;
        const variant = String(m.product_id ?? '');
        const template = String(m.product_template_id ?? '');
        if (variant && template && variant !== template && !templateToVariant[template]) {
          templateToVariant[template] = variant;
        }
      }
    }
  }

  const itemData: Record<string, unknown>[] = [];
  let totalNetSum = 0;
  let totalVatSum = 0;

  for (let idx = 0; idx < rawItems.length; idx++) {
    const item = { ...(rawItems[idx] as Record<string, unknown>) };
    const qty = Number(item.quantity ?? 1) || 1;
    const netUnit = r5(Number(item.unitPrice ?? 0) || 0);
    const netLine = r5(netUnit * qty);
    const vatLine = r2((netLine * taxRate) / 100);
    const totalLine = r5(netLine + vatLine);
    totalNetSum += netLine;
    totalVatSum += vatLine;

    const storedId = String(item.productId ?? '');
    const productId = templateToVariant[storedId] ?? storedId;
    const itemCode = productId ? `EG-${rin}-${productId}` : `EG-${rin}-${idx + 1}`;
    const desc = String(item.productName ?? 'صنف')
      .trim()
      .replace(/[\t\r\n]+/g, ' ');

    itemData.push({
      internalCode: String(idx + 1),
      description: desc,
      itemType: 'EGS',
      itemCode,
      unitType: 'EA',
      quantity: qty,
      unitPrice: netUnit,
      netSale: netLine,
      totalSale: netLine,
      total: totalLine,
      taxableItems: [{ taxType: 'T1', amount: vatLine, subType: 'V009', rate: taxRate }],
    });
  }

  const totalSalesR = r5(totalNetSum);
  const totalVatR = r2(totalVatSum);
  const totalAmtR = r5(totalSalesR + totalVatR);
  const building = String(integration.addressBuildingNumber ?? '');
  const buildingNumber = building.length >= 4 ? building : building.padStart(4, '0');

  return {
    header: {
      dateTimeIssued: dtStr,
      receiptNumber,
      uuid: '',
      previousUUID: previousUUID ?? '',
      currency: 'EGP',
      exchangeRate: 0,
    },
    documentType: { receiptType: 's', typeVersion: '1.2' },
    seller: {
      rin,
      companyTradeName,
      branchCode: integration.branchCode?.trim() || '0',
      branchAddress: {
        country: integration.addressCountry?.trim() || 'EG',
        governate: integration.addressGovernate ?? '',
        regionCity: integration.addressRegionCity ?? '',
        street: integration.addressStreet ?? '',
        buildingNumber,
      },
      deviceSerialNumber: integration.serialNumber,
      activityCode: activityCode.trim() || '5610',
    },
    buyer: { type: 'P', name: 'عميل عام' },
    itemData,
    totalSales: totalSalesR,
    netAmount: totalSalesR,
    totalAmount: totalAmtR,
    taxTotals: [{ taxType: 'T1', amount: totalVatR }],
    paymentMethod: mapPaymentMethod(String(sale.paymentMethod ?? '')),
  };
}

async function httpSend(
  method: string,
  url: string,
  headers: Record<string, string>,
  body?: string,
): Promise<{ status: number; data: unknown }> {
  const res = await fetch(url, {
    method,
    headers,
    body,
  });
  const text = await res.text();
  let data: unknown = text;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    /* keep text */
  }
  return { status: res.status, data };
}

/** Optional Dishflow hosting proxy when direct ETA is blocked. */
async function viaProxy(
  proxyBase: string,
  method: string,
  url: string,
  headers: Record<string, string>,
  body?: string,
): Promise<{ status: number; data: unknown }> {
  const res = await fetch(`${proxyBase.replace(/\/+$/, '')}/api/etaproxy`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ method, url, headers, ...(body != null ? { body } : {}) }),
  });
  const payload = (await res.json()) as { status?: number; data?: unknown; error?: string };
  if (res.status >= 400) {
    return { status: 0, data: payload.error ?? res.status };
  }
  if (payload.status != null) return { status: Number(payload.status), data: payload.data };
  return { status: 0, data: payload };
}

export async function getEtaToken(
  integration: EtaIntegration,
  useSandbox: boolean,
  opts?: { proxyBase?: string },
): Promise<string | null> {
  const id = integration.clientId.trim();
  const secret = integration.clientSecret.trim();
  const serial = integration.serialNumber.trim();
  if (!id || !secret) return null;

  if (
    tokenCache &&
    tokenCache.forId === id &&
    Date.now() < tokenCache.expiry.getTime() - 2 * 60 * 1000
  ) {
    return tokenCache.token;
  }

  const tokenUrl = useSandbox ? SANDBOX_TOKEN : PROD_TOKEN;
  const headers: Record<string, string> = {
    'Content-Type': 'application/x-www-form-urlencoded',
    posserial: serial,
    pososversion: 'windows',
    posmodelframework: '',
  };
  const body = `grant_type=client_credentials&client_id=${encodeURIComponent(id)}&client_secret=${encodeURIComponent(secret)}`;

  let result: { status: number; data: unknown };
  try {
    result = await httpSend('POST', tokenUrl, headers, body);
  } catch {
    if (opts?.proxyBase) {
      result = await viaProxy(opts.proxyBase, 'POST', tokenUrl, headers, body);
    } else {
      return null;
    }
  }
  if (result.status !== 200 && opts?.proxyBase) {
    result = await viaProxy(opts.proxyBase, 'POST', tokenUrl, headers, body);
  }

  if (result.status === 200 && result.data && typeof result.data === 'object') {
    const m = result.data as Record<string, unknown>;
    const token = String(m.access_token ?? '');
    const expiresIn = Number(m.expires_in ?? 3600) || 3600;
    if (token) {
      tokenCache = {
        token,
        forId: id,
        expiry: new Date(Date.now() + expiresIn * 1000),
      };
      return token;
    }
  }
  return null;
}

function isDuplicateRejection(rejectedFirst: unknown): boolean {
  let s: string;
  try {
    s = JSON.stringify(rejectedFirst).toLowerCase();
  } catch {
    s = String(rejectedFirst).toLowerCase();
  }
  return (
    s.includes('duplicate') ||
    s.includes('already') ||
    s.includes('مكرر') ||
    s.includes('سبق') ||
    s.includes('مرسل بالفعل')
  );
}

export async function submitReceipt(opts: {
  sale: Record<string, unknown>;
  company: EtaCompany;
  proxyBase?: string;
  previousUUID?: string;
}): Promise<EtaSubmitResult> {
  const { sale, company, proxyBase, previousUUID } = opts;
  if (!company.rin.trim()) {
    return {
      success: false,
      acceptedDocuments: 0,
      rejectedDocuments: 0,
      error: 'إعدادات ETA ناقصة — أضف الرقم الضريبي (RIN) أولاً',
    };
  }
  const integration = pickIntegration(company, String(sale.orderType ?? ''));
  if (!integration) {
    return {
      success: false,
      acceptedDocuments: 0,
      rejectedDocuments: 0,
      error: 'لا يوجد تكامل ETA',
    };
  }

  const token = await getEtaToken(integration, company.useSandbox, { proxyBase });
  if (!token) {
    return {
      success: false,
      acceptedDocuments: 0,
      rejectedDocuments: 0,
      error: 'مش متوصل بـ ETA — تحقق من الإعدادات',
    };
  }

  const receipt = buildReceiptJson({
    sale,
    integration,
    rin: company.rin,
    companyTradeName: company.companyTradeName,
    activityCode: company.activityCode || '5610',
    previousUUID,
  });
  const uuid = computeUuid(receipt);
  (receipt.header as Record<string, unknown>).uuid = uuid;

  const apiBase = company.useSandbox ? SANDBOX_API : PROD_API;
  const url = `${apiBase}/api/v1/receiptsubmissions`;
  const headers = {
    Authorization: `Bearer ${token}`,
    'Content-Type': 'application/json',
    Accept: 'application/json',
  };
  const body = JSON.stringify({ receipts: [receipt], signatures: [] });

  const handle = (status: number, data: unknown): EtaSubmitResult => {
    if (status === 202 && data && typeof data === 'object') {
      const m = data as Record<string, unknown>;
      const accepted = Array.isArray(m.acceptedDocuments) ? m.acceptedDocuments : [];
      const rejected = Array.isArray(m.rejectedDocuments) ? m.rejectedDocuments : [];
      let longId: string | undefined;
      if (accepted.length && accepted[0] && typeof accepted[0] === 'object') {
        longId = String((accepted[0] as Record<string, unknown>).longId ?? '') || undefined;
      }
      if (accepted.length) {
        return {
          success: true,
          submissionId: m.submissionId != null ? String(m.submissionId) : undefined,
          uuid,
          longId,
          acceptedDocuments: accepted.length,
          rejectedDocuments: rejected.length,
        };
      }
      if (rejected.length && isDuplicateRejection(rejected[0])) {
        return {
          success: true,
          submissionId: m.submissionId != null ? String(m.submissionId) : undefined,
          uuid,
          longId,
          acceptedDocuments: 0,
          rejectedDocuments: rejected.length,
        };
      }
      let rejectionError: string | undefined;
      if (rejected.length) {
        const first = rejected[0];
        if (first && typeof first === 'object') {
          const f = first as Record<string, unknown>;
          const errs = f.error ?? f.validationResults ?? f.errors;
          rejectionError = `رُفض من ETA: ${errs != null ? JSON.stringify(errs) : JSON.stringify(first)}`;
        } else {
          rejectionError = `رُفض من ETA: ${first}`;
        }
      }
      return {
        success: false,
        submissionId: m.submissionId != null ? String(m.submissionId) : undefined,
        uuid,
        longId,
        acceptedDocuments: 0,
        rejectedDocuments: rejected.length,
        error: rejectionError ?? 'رُفض من ETA — تحقق من بيانات الإيصال',
      };
    }
    return {
      success: false,
      acceptedDocuments: 0,
      rejectedDocuments: 0,
      error: `HTTP ${status}: ${typeof data === 'string' ? data : JSON.stringify(data)}`,
    };
  };

  let result: EtaSubmitResult | null = null;
  for (let attempt = 1; attempt <= 2; attempt++) {
    let status = 0;
    let data: unknown = 'no response';
    try {
      const r = await httpSend('POST', url, headers, body);
      status = r.status;
      data = r.data;
      if (status === 0 || (status >= 500 && proxyBase)) {
        const p = await viaProxy(proxyBase!, 'POST', url, headers, body);
        status = p.status;
        data = p.data;
      }
    } catch (e) {
      if (proxyBase) {
        try {
          const p = await viaProxy(proxyBase, 'POST', url, headers, body);
          status = p.status;
          data = p.data;
        } catch (e2) {
          result = {
            success: false,
            acceptedDocuments: 0,
            rejectedDocuments: 0,
            error: `تعذّر تأكيد الإرسال: ${e2}`,
          };
          continue;
        }
      } else {
        result = {
          success: false,
          acceptedDocuments: 0,
          rejectedDocuments: 0,
          error: `تعذّر تأكيد الإرسال: ${e}`,
        };
        continue;
      }
    }
    if (status === 0) {
      result = {
        success: false,
        acceptedDocuments: 0,
        rejectedDocuments: 0,
        error: `تعذّر تأكيد الإرسال: ${data}`,
      };
      continue;
    }
    result = handle(status, data);
    break;
  }
  return result ?? { success: false, acceptedDocuments: 0, rejectedDocuments: 0, error: 'فشل الإرسال' };
}
