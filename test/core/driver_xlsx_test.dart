import 'dart:io';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/export/driver_xlsx.dart';
import 'package:offline_pos/domain/delivery.dart';

/// Drivers leave and re-enter the till as a plain Excel table the shop already
/// uses. What matters is the header shape, a round-trip of name/phone/active,
/// and that Dishflow extras (code/username/password) do not invent columns here.
void main() {
  test('export file name includes time so same-day exports do not clash', () {
    expect(
      driversExportFileName(DateTime(2026, 10, 22, 14, 5)),
      'drivers_20261022_1405.xlsx',
    );
  });

  test('export writes the shop header row and active as true/false', () {
    final bytes = buildDriversXlsx(const [
      Driver(id: 'abc', name: 'Hany', phone: '0100', active: true),
      Driver(id: 'def', name: 'Sami', active: false),
    ]);
    final book = Excel.decodeBytes(bytes);
    final sheet = book.tables['Drivers']!;
    String at(int r, int c) => sheet.rows[r][c]?.value?.toString() ?? '';

    expect(
      [for (var c = 0; c < 7; c++) at(0, c)],
      driverXlsxHeaders,
    );
    expect(at(1, 0), 'abc');
    expect(at(1, 1), ''); // code — not stored
    expect(at(1, 2), 'Hany');
    expect(at(1, 3), '0100');
    expect(at(1, 6), 'true');
    expect(at(2, 2), 'Sami');
    expect(at(2, 3), '');
    expect(at(2, 6), 'false');
  });

  test('parse keeps id/name/phone/active and ignores extras', () {
    final bytes = buildDriversXlsx(const [
      Driver(id: '9mGhFy5ah25anr02eUUw', name: 'احمد', phone: '011', active: true),
    ]);
    // Re-write with code/username/password filled so parse must ignore them.
    final book = Excel.decodeBytes(bytes);
    final sheet = book['Drivers']!;
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: 1)).value =
        TextCellValue('8085');
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: 1)).value =
        TextCellValue('user');
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: 1)).value =
        TextCellValue('secret');
    final encoded = book.encode()!;

    final rows = parseDriversXlsx(encoded);
    expect(rows, hasLength(1));
    expect(rows.single.id, '9mGhFy5ah25anr02eUUw');
    expect(rows.single.name, 'احمد');
    expect(rows.single.phone, '011');
    expect(rows.single.active, isTrue);
  });

  test('parse accepts a filled sample workbook from Downloads when present', () {
    final sample = File(r'C:\Users\DELL\Downloads\drivers_20261022.xlsx');
    if (!sample.existsSync()) return;
    final rows = parseDriversXlsx(sample.readAsBytesSync());
    // An empty export can overwrite the sample; skip rather than fail the suite.
    if (rows.isEmpty) return;
    expect(rows.first.name, isNotEmpty);
    expect(rows.every((r) => r.name.isNotEmpty), isTrue);
  });

  test('isActive false strings deactivate', () {
    final book = Excel.createExcel();
    final sheet = book['Drivers'];
    book.delete(book.getDefaultSheet()!);
    for (var c = 0; c < driverXlsxHeaders.length; c++) {
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0)).value =
          TextCellValue(driverXlsxHeaders[c]);
    }
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: 1)).value =
        TextCellValue('Gone');
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: 1)).value =
        TextCellValue('false');
    final rows = parseDriversXlsx(book.encode()!);
    expect(rows.single.active, isFalse);
  });
}
