import 'package:pdf/widgets.dart' as pw;

import 'export_header.dart';

/// Builds a titled-table PDF from the same header/rows the CSV and the workbook
/// use, so a manager who wants a printable page gets the identical data. Kept
/// beside [buildCsv] so every export renders one shape of table.
///
/// [head] adds the shop / period / who-ran-it block under the title and repeats
/// nothing on later pages: the table header is what a reader needs there, and the
/// pdf package repeats that itself.
Future<List<int>> buildPdfTable(
  String title,
  List<String> header,
  List<List<String>> rows, {
  ExportHeader? head,
}) async {
  final doc = pw.Document();
  doc.addPage(
    pw.MultiPage(
      build: (context) => [
        pw.Header(level: 0, child: pw.Text(head?.title ?? title)),
        if (head != null && head.lines.isNotEmpty) ...[
          for (final (label, value) in head.lines)
            pw.Text('$label: $value', style: const pw.TextStyle(fontSize: 10)),
          pw.SizedBox(height: 12),
        ],
        pw.TableHelper.fromTextArray(
          headers: header,
          data: rows,
          headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
          cellAlignment: pw.Alignment.centerLeft,
        ),
      ],
    ),
  );
  return doc.save();
}
