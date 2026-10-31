/// The shared voucher server, asked with its admin key. The reports site never
/// sees that key: a signed-in owner talks to these methods through /api/vouchers.
export interface VoucherOverview {
  percent: number;
  discounts: { id: string; name: string; percent: number }[];
  ranges: { from: number; to: number; discount_id?: string | null; percent?: number }[];
  branches: { name: string; key: string; connected?: boolean; last_seen?: string | null }[];
  rows: Record<string, unknown>[];
}

export interface VoucherAdmin {
  overview(): Promise<VoucherOverview>;
  addDiscount(name: string, percent: number): Promise<void>;
  removeDiscount(index: number): Promise<void>;
  addRange(from: number, to: number, discountId?: string): Promise<void>;
  removeRange(index: number): Promise<void>;
  setRangeDiscount(index: number, discountId: string | null): Promise<void>;
  addBranch(name: string): Promise<{ name: string; key: string }>;
}

export class VoucherServerError extends Error {
  constructor(message: string) {
    super(message);
  }
}

/// Empty address or key means vouchers are not connected, and the site says so.
export function voucherAdmin(baseUrl: string, adminKey: string): VoucherAdmin | null {
  const base = baseUrl.trim().replace(/\/+$/, '');
  const key = adminKey.trim();
  if (!base || !key) return null;
  return new HttpVoucherAdmin(base, key);
}

class HttpVoucherAdmin implements VoucherAdmin {
  constructor(
    private readonly base: string,
    private readonly key: string,
  ) {}

  async overview(): Promise<VoucherOverview> {
    const body = await this.call('GET', '/v1/admin/overview');
    return {
      percent: Number(body.percent ?? 15),
      discounts: Array.isArray(body.discounts) ? (body.discounts as VoucherOverview['discounts']) : [],
      ranges: Array.isArray(body.ranges) ? (body.ranges as VoucherOverview['ranges']) : [],
      branches: Array.isArray(body.branches) ? (body.branches as VoucherOverview['branches']) : [],
      rows: Array.isArray(body.rows) ? (body.rows as Record<string, unknown>[]) : [],
    };
  }

  async addDiscount(name: string, percent: number): Promise<void> {
    await this.call('POST', '/v1/admin/discounts', { name, percent });
  }

  async removeDiscount(index: number): Promise<void> {
    await this.call('POST', '/v1/admin/discounts/remove', { index });
  }

  async addRange(from: number, to: number, discountId?: string): Promise<void> {
    await this.call('POST', '/v1/admin/ranges', {
      from,
      to,
      ...(discountId ? { discount_id: discountId } : {}),
    });
  }

  async removeRange(index: number): Promise<void> {
    await this.call('POST', '/v1/admin/ranges/remove', { index });
  }

  async setRangeDiscount(index: number, discountId: string | null): Promise<void> {
    await this.call('POST', '/v1/admin/ranges/discount', { index, discount_id: discountId ?? '' });
  }

  async addBranch(name: string): Promise<{ name: string; key: string }> {
    const body = await this.call('POST', '/admin/branches', { name });
    return { name: String(body.name ?? name), key: String(body.key ?? '') };
  }

  private async call(method: string, path: string, payload?: object): Promise<Record<string, unknown>> {
    let res: Response;
    try {
      res = await fetch(`${this.base}${path}`, {
        method,
        headers: {
          'x-admin-key': this.key,
          ...(payload ? { 'content-type': 'application/json' } : {}),
        },
        body: payload ? JSON.stringify(payload) : undefined,
      });
    } catch {
      throw new VoucherServerError('voucher server is not reachable');
    }
    const text = await res.text();
    let body: Record<string, unknown> = {};
    if (text) {
      try {
        body = JSON.parse(text) as Record<string, unknown>;
      } catch {
        throw new VoucherServerError('voucher server sent an unreadable answer');
      }
    }
    if (!res.ok || body.ok === false) {
      throw new VoucherServerError(
        body.error === 'invalid'
          ? 'that number range is not valid'
          : body.error === 'discount'
            ? 'that discount is not valid'
            : 'voucher server refused the request',
      );
    }
    return body;
  }
}
