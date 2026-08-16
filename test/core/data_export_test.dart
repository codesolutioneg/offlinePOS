import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/export/data_export.dart';
import 'package:offline_pos/core/export/export_header.dart';

void main() {
  test('a CSV is the header plus one line per row', () {
    final csv = buildCsv(
      ['id', 'actor', 'event'],
      [
        ['1', 'sara', 'order.paid'],
        ['2', 'omar', 'order.cancelled'],
      ],
    );
    final lines = csv.split('\n');
    expect(lines.length, 3); // header + 2 rows
    expect(lines.first, 'id,actor,event');
    expect(lines[1], '1,sara,order.paid');
    expect(lines[2], '2,omar,order.cancelled');
  });

  test('fields with commas, quotes or newlines are escaped', () {
    expect(csvField('plain'), 'plain');
    expect(csvField('a,b'), '"a,b"');
    expect(csvField('say "hi"'), '"say ""hi"""');
    expect(csvField('line1\nline2'), '"line1\nline2"');

    final csv = buildCsv(
      ['name', 'note'],
      [
        ['Fish, chips', 'well "done"'],
      ],
    );
    expect(csv.split('\n')[1], '"Fish, chips","well ""done"""');
  });

  test('a headed CSV opens with the report name and its provenance', () {
    final csv = buildCsv(
      ['Reason', 'Amount'],
      [
        ['Taxi', '25.00'],
      ],
      head: const ExportHeader(title: 'Expenses', lines: [
        ('Shop', 'Nour Grill, Zamalek'),
        ('Period', 'Today'),
      ]),
    );
    expect(csv.split('\n'), [
      'Expenses',
      // The shop's own comma must not split its line into two columns.
      'Shop,"Nour Grill, Zamalek"',
      'Period,Today',
      '',
      'Reason,Amount',
      'Taxi,25.00',
    ]);
  });

  test('the export file name stamps the timestamp down to the minute', () {
    final at = DateTime(2026, 8, 14, 9, 5);
    expect(exportFileName('report-sales', at, 'csv'), 'report-sales-20260814-0905.csv');
    expect(exportFileName('audit', at, 'pdf'), 'audit-20260814-0905.pdf');
  });
}
