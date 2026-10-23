import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/report_sources.dart';
import 'package:offline_pos/domain/shop_sessions.dart';

void main() {
  test('live Emad payloads from reports DB collapse to one', () {
    final rows = [
      {
        'id': 'SH1792042500906606',
        'uuid': 'c436bd13-1fcf-49eb-addf-4cb9c3ed2bf6',
        'closed_at': '2026-10-15T21:42:07.958540Z',
        'movements': '[]',
        'opened_at': '2026-10-15T05:35:00.906606Z',
        'cashier_id': 'dishflow-97',
        'opening_float': 0,
        'closing_counted': 7243.97,
      },
      {
        'id': 'SH1792042509208878',
        'uuid': '99a33804-313f-4c55-a840-d49cf0ccc903',
        'closed_at': '2026-10-15T21:42:17.557631Z',
        'movements': '[]',
        'opened_at': '2026-10-15T05:35:09.208878Z',
        'cashier_id': 'dishflow-97',
        'opening_float': 0,
        'closing_counted': 0,
      },
      {
        'id': 'SH1792043258727317',
        'uuid': 'e91f9642-fe24-4828-adc3-b1cc34a83a1a',
        'closed_at': '2026-10-15T21:42:08.350095Z',
        'movements': '[]',
        'opened_at': '2026-10-15T05:47:38.727317Z',
        'cashier_id': 'dishflow-97',
        'opening_float': 0,
        'closing_counted': 0,
      },
      {
        'id': 'SH1791977402336671',
        'uuid': '6c5ae6ed-473a-4d73-88c6-4f902dd17f1d',
        'closed_at': null,
        'movements': '[]',
        'opened_at': '2026-10-14T11:30:02.336671Z',
        'cashier_id': 'dishflow-66',
        'opening_float': 0,
        'closing_counted': null,
      },
    ];
    final shifts = [for (final r in rows) shiftFromRow(r)];
    final collapsed = collapseShopShiftClones(shifts);
    expect(collapsed, hasLength(2));
    final emad = collapsed.where((s) => s.cashierId == 'dishflow-97').toList();
    expect(emad, hasLength(1));
    expect(emad.single.closingCounted, 7243.97);
  });
}
