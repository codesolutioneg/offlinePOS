import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/export/export_header.dart';
import 'package:offline_pos/core/export/xlsx_export.dart';

/// The workbook a report downloads as.
///
/// A CSV is a text file a spreadsheet guesses at; this is the format the shop asked
/// for, so what matters is that it opens, that the header block survives, and that
/// an amount comes back as a number rather than as text nobody can sum.
void main() {
  const head = ExportHeader(title: 'Expenses', lines: [
    ('Shop', 'Nour Grill'),
    ('Period', 'Today'),
    ('Run by', 'sara'),
  ]);

  Sheet decode(List<int> bytes) {
    final book = Excel.decodeBytes(bytes);
    return book.tables[book.tables.keys.single]!;
  }

  test('the header block sits above the table', () {
    final bytes = buildXlsxTable(
      const ['Reason', 'Amount'],
      const [
        ['Taxi', '25.00'],
      ],
      head: head,
    );
    final sheet = decode(bytes!);
    String at(int row, int col) => sheet.rows[row][col]?.value?.toString() ?? '';

    expect(at(0, 0), 'Expenses');
    expect(at(1, 0), 'Shop');
    expect(at(1, 1), 'Nour Grill');
    expect(at(3, 1), 'sara');
    // A blank row, then the column names, then the data.
    expect(at(5, 0), 'Reason');
    expect(at(6, 0), 'Taxi');
  });

  test('an amount comes back as a number, not as text', () {
    final bytes = buildXlsxTable(
      const ['Reason', 'Amount'],
      const [
        ['Taxi', '25.50'],
      ],
      head: head,
    );
    final sheet = decode(bytes!);
    // The whole point of a workbook over a CSV: the column sums.
    expect(sheet.rows[6][1]?.value, isA<DoubleCellValue>());
    expect((sheet.rows[6][1]!.value! as DoubleCellValue).value, 25.5);
    expect(sheet.rows[6][0]?.value, isA<TextCellValue>());
  });

  test('a report with no rows still opens, with its header', () {
    final bytes = buildXlsxTable(const ['Reason', 'Amount'], const [], head: head);
    final sheet = decode(bytes!);
    expect(sheet.rows[0][0]?.value?.toString(), 'Expenses');
    expect(sheet.rows[5][0]?.value?.toString(), 'Reason');
  });
}
