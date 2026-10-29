import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/web_reports/site_api.dart';
import 'package:offline_pos/web_reports/voucher_summary.dart';

void main() {
  test('used, leftover and value come from the numbers and the paid rows', () {
    final data = SiteVouchers(
      percent: 15,
      discounts: const [],
      ranges: const [
        SiteVoucherRange(from: 1, to: 10, percent: 15),
        SiteVoucherRange(from: 8, to: 12, percent: 15),
      ],
      branches: const [],
      rows: const [
        SiteVoucherUse(
          code: '1',
          serial: 1,
          status: 'used',
          branchName: 'Main',
          customerName: '2',
          discountAmount: 115.49,
        ),
        SiteVoucherUse(
          code: '2',
          serial: 2,
          status: 'held',
          branchName: 'Main',
          customerName: '3',
        ),
        SiteVoucherUse(
          code: '1',
          serial: 1,
          status: 'held',
          branchName: 'Main',
          customerName: '2',
        ),
      ],
    );

    final totals = voucherTotals(data);
    expect(totals.total, 12);
    expect(totals.used, 1);
    expect(totals.waiting, 1);
    expect(totals.remaining, 10);
    expect(totals.value, closeTo(115.49, 0.001));

    final first = voucherRangeCounts(data).first;
    expect(first.used, 1);
    expect(first.waiting, 1);
    expect(first.remaining, 8);
    expect(first.value, closeTo(115.49, 0.001));
  });
}
