import 'package:pdf/widgets.dart' as pw;

/// Builds a simple titled-table PDF from the same header/rows the CSV export
/// uses, so a manager who wants a printable page gets the identical data. Kept
/// beside [buildCsv] so both exports render one shape of table.
Future<List<int>> buildPdfTable(
  String title,
  List<String> header,
  List<List<String>> rows,
) async {
  final doc = pw.Document();
  doc.addPage(
    pw.MultiPage(
      build: (context) => [
        pw.Header(level: 0, child: pw.Text(title)),
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
