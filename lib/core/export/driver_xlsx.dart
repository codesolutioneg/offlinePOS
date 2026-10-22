import 'package:excel/excel.dart';

import '../../domain/delivery.dart';

/// Columns the shop's driver spreadsheet already uses (Dishflow-style export).
///
/// The till only stores [id], [name], [phone] and active. [code], [username] and
/// [password] round-trip as empty so the same workbook opens elsewhere without
/// inventing fields we do not keep.
const driverXlsxHeaders = [
  'id',
  'code',
  'name',
  'phone',
  'username',
  'password',
  'isActive',
];

/// One row read from a drivers workbook, already reduced to what the till stores.
class DriverXlsxRow {
  const DriverXlsxRow({
    this.id,
    required this.name,
    this.phone,
    this.active = true,
  });

  final String? id;
  final String name;
  final String? phone;
  final bool active;
}

/// `drivers_20261022_1434.xlsx` — date + time so a second export the same day
/// does not wipe an earlier import file sitting in Downloads.
String driversExportFileName(DateTime at) {
  String two(int n) => n.toString().padLeft(2, '0');
  return 'drivers_${at.year}${two(at.month)}${two(at.day)}'
      '_${two(at.hour)}${two(at.minute)}.xlsx';
}

/// Flat Drivers sheet: header row, then one row per driver. No report banner —
/// the sample workbook is a plain table a manager re-imports.
List<int> buildDriversXlsx(List<Driver> drivers) {
  final book = Excel.createExcel();
  const sheetName = 'Drivers';
  final seeded = book.getDefaultSheet();
  final sheet = book[sheetName];
  if (seeded != null && seeded != sheetName) book.delete(seeded);

  for (var c = 0; c < driverXlsxHeaders.length; c++) {
    sheet
        .cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0))
        .value = TextCellValue(driverXlsxHeaders[c]);
  }

  for (var i = 0; i < drivers.length; i++) {
    final d = drivers[i];
    final values = [
      d.id,
      '',
      d.name,
      d.phone ?? '',
      '',
      '',
      d.active ? 'true' : 'false',
    ];
    for (var c = 0; c < values.length; c++) {
      sheet
          .cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: i + 1))
          .value = TextCellValue(values[c]);
    }
  }

  return book.encode()!;
}

/// Reads a Drivers workbook. Rows without a name are skipped. Unknown extra
/// columns are ignored; missing optional columns default sensibly.
List<DriverXlsxRow> parseDriversXlsx(List<int> bytes) {
  final book = Excel.decodeBytes(bytes);
  if (book.tables.isEmpty) return const [];

  // Prefer a sheet named Drivers; otherwise the first sheet.
  final sheet = book.tables['Drivers'] ?? book.tables.values.first;
  if (sheet.maxRows < 1) return const [];

  final headerRow = sheet.rows.first;
  final index = <String, int>{};
  for (var c = 0; c < headerRow.length; c++) {
    final key = _cellText(headerRow[c]).trim().toLowerCase();
    if (key.isNotEmpty) index[key] = c;
  }
  if (!index.containsKey('name')) {
    throw FormatException('Drivers workbook needs a name column');
  }

  String? col(List<Data?> row, String key) {
    final i = index[key];
    if (i == null || i >= row.length) return null;
    final t = _cellText(row[i]).trim();
    return t.isEmpty ? null : t;
  }

  final out = <DriverXlsxRow>[];
  for (var r = 1; r < sheet.rows.length; r++) {
    final row = sheet.rows[r];
    final name = col(row, 'name');
    if (name == null) continue;
    out.add(DriverXlsxRow(
      id: col(row, 'id'),
      name: name,
      phone: col(row, 'phone'),
      active: _parseActive(col(row, 'isactive') ?? col(row, 'active')),
    ));
  }
  return out;
}

String _cellText(Data? cell) {
  final v = cell?.value;
  if (v == null) return '';
  if (v is TextCellValue) return v.value.toString();
  if (v is IntCellValue) return '${v.value}';
  if (v is DoubleCellValue) {
    final n = v.value;
    return n == n.roundToDouble() ? '${n.toInt()}' : '$n';
  }
  if (v is BoolCellValue) return v.value ? 'true' : 'false';
  return v.toString();
}

bool _parseActive(String? raw) {
  if (raw == null) return true;
  switch (raw.trim().toLowerCase()) {
    case '0':
    case 'false':
    case 'no':
    case 'n':
    case 'off':
      return false;
    default:
      return true;
  }
}
