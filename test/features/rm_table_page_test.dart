import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/features/reports/rm/rm_layout.dart';
import 'package:offline_pos/features/reports/rm/rm_table_page.dart';

void main() {
  RmDocument page(List<String> header, List<List<String>> rows) =>
      layOutReportTable(
        shop: 'Nour Grill',
        title: 'Session detail',
        period: 'Today',
        filter: 'None',
        ranAt: DateTime(2026, 10, 7, 15, 41),
        header: header,
        rows: rows,
      );

  /// The table's own cells: everything set in the body size, under the heading.
  List<RmPlaced> cells(RmDocument doc, String anyCell) {
    final size =
        doc.items.firstWhere((i) => i.text == anyCell).cell.fontSize;
    return [
      for (final i in doc.items)
        if (i.cell.kind == RmKind.text && i.cell.fontSize == size && i.y > 120)
          i,
    ];
  }

  test('a narrow table stays on an upright page', () {
    final doc = page(const [
      'Product',
      'Units',
      'Revenue'
    ], const [
      ['Pizza', '1', '250.50'],
    ]);
    expect(doc.pageWidth, lessThan(doc.pageHeight));
  });

  test('a wide table turns the page and no column runs into the next', () {
    final doc = page(const [
      'Order',
      'Bill time',
      'Revenue centre',
      'Table',
      'Cashier',
      'Covers',
      'Sub-Total',
      'Check discount',
      'Taxes',
      'Total',
      'Tenders'
    ], const [
      [
        '953',
        '2026-10-07 11:47',
        'Car delivery',
        'T1',
        'yasser-1790669462829797',
        '0',
        '274.99',
        '0.00',
        '38.50',
        '313.49',
        'Visa 313.49'
      ],
    ]);

    expect(doc.pageWidth, greaterThan(doc.pageHeight));
    final row = cells(doc, '953')
        .where((i) => i.y == doc.items.firstWhere((i) => i.text == '953').y)
        .toList()
      ..sort((a, b) => a.x.compareTo(b.x));
    expect(row, hasLength(11));
    for (var i = 1; i < row.length; i++) {
      expect(row[i].x, greaterThanOrEqualTo(row[i - 1].x + row[i - 1].width),
          reason: '${row[i].text} starts inside ${row[i - 1].text}');
    }
    // And the whole of it is on the page.
    expect(row.last.x + row.last.width, lessThanOrEqualTo(doc.pageWidth - 36));
  });
}
