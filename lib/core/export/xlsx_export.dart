import 'package:excel/excel.dart';

import 'export_header.dart';

/// Builds a real .xlsx workbook from the header/rows every export shares.
///
/// A CSV is a text file a spreadsheet guesses at: the shop's own name splits on its
/// comma, a total loses its type, and the header block reads as noise. Dishflow
/// solved this with the `excel` package and per-report builders; this is the same
/// package with one generic builder, because every report here is already reduced
/// to a title, a header block and a table, and eighteen near-identical builders
/// would drift apart within a release.
///
/// A cell that parses as a number is written as a number, so the totals a manager
/// wants to sum are summable rather than text.
List<int>? buildXlsxTable(
  List<String> header,
  List<List<String>> rows, {
  required ExportHeader head,
  String sheetName = 'Report',
}) {
  final book = Excel.createExcel();
  // createExcel seeds a 'Sheet1' that would otherwise ship empty beside ours.
  final seeded = book.getDefaultSheet();
  final sheet = book[sheetName];
  if (seeded != null && seeded != sheetName) book.delete(seeded);

  final titleStyle = CellStyle(bold: true, fontSize: 14);
  final labelStyle = CellStyle(bold: true);
  final headerStyle = CellStyle(
    bold: true,
    backgroundColorHex: ExcelColor.fromHexString('FFE2E8F0'),
  );

  void put(int col, int row, String value, {CellStyle? style, bool typed = false}) {
    final cell =
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row));
    final number = typed ? double.tryParse(value) : null;
    cell.value = number == null ? TextCellValue(value) : DoubleCellValue(number);
    if (style != null) cell.cellStyle = style;
  }

  var r = 0;
  put(0, r++, head.title, style: titleStyle);
  for (final (label, value) in head.lines) {
    put(0, r, label, style: labelStyle);
    put(1, r, value);
    r++;
  }
  // One blank row between the header block and the table, matching the CSV.
  r++;

  for (var c = 0; c < header.length; c++) {
    put(c, r, header[c], style: headerStyle);
  }
  r++;

  for (final row in rows) {
    for (var c = 0; c < row.length; c++) {
      put(c, r, row[c], typed: true);
    }
    r++;
  }

  return book.encode();
}
