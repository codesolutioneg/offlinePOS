import 'package:pdf/widgets.dart' as pw;

import 'export_header.dart';
import 'pdf_fonts.dart';

/// Builds a titled-table PDF from the same header/rows the CSV and the workbook
/// use, so a manager who wants a printable page gets the identical data. Kept
/// beside [buildCsv] so every export renders one shape of table.
///
/// [head] adds the shop / period / who-ran-it block under the title and repeats
/// nothing on later pages: the table header is what a reader needs there, and the
/// pdf package repeats that itself.
///
/// This is the one place the app turns rows into a PDF, so the Arabic handling
/// lives here rather than on each screen that offers a download.
Future<List<int>> buildPdfTable(
  String title,
  List<String> header,
  List<List<String>> rows, {
  ExportHeader? head,
}) async {
  final heading = head?.title ?? title;
  final subtitles = head?.lines ?? const <(String, String)>[];

  // Only a document that has something the built-in fonts cannot draw pays for an
  // embedded one. A Latin-only report is built exactly as it was before.
  final theme = pdfNeedsEmbeddedFont([
    heading,
    for (final (label, value) in subtitles) ...[label, value],
    ...header,
    for (final row in rows) ...row,
  ])
      ? await unicodePdfTheme()
      : null;

  // The page reads the way its own title reads. An Arabic report is a
  // right-to-left page down to its header block; an English report listing Arabic
  // dish names stays left to right, and only the names turn round.
  final rtl = theme != null && pdfIsRightToLeft(heading);
  final pageDirection = rtl ? pw.TextDirection.rtl : null;

  // Where a piece of text sits in the room it is given: the title, and any name
  // long enough to wrap. Said outright rather than left to follow each string's
  // own direction, so an Arabic dish name does not line up against the far side
  // of an otherwise English table. Null on the Latin path leaves the package's
  // own default in place.
  final align = theme == null
      ? null
      : (rtl ? pw.TextAlign.right : pw.TextAlign.left);

  // Direction per string, not per document: the package only reorders and joins
  // text that is marked right-to-left, so an Arabic cell in an English table has
  // to say so itself or it prints unjoined and back to front. Latin runs and the
  // digits in a money column are left alone by that pass, which is what keeps a
  // total reading 1,250.00 in an Arabic report.
  pw.TextDirection? directionOf(String s) =>
      theme != null && pdfIsRightToLeft(s) ? pw.TextDirection.rtl : pageDirection;

  pw.Widget cell(String text, {pw.TextStyle? style}) => pw.Text(
        text,
        style: style,
        textAlign: align,
        textDirection: directionOf(text),
      );

  const small = pw.TextStyle(fontSize: 10);

  // One line of the shop / period / who-ran-it block. Once the page carries
  // Arabic, the label and the value are two pieces of text rather than one
  // string: joined, they are a single paragraph to the bidirectional pass, and
  // that pass rearranges a date sitting inside an Arabic line, so the stamp came
  // back reading 16-08-2026. Apart, they never meet, and the row itself turns
  // round with the page.
  pw.Widget subtitle(String label, String value) => theme == null
      ? pw.Text('$label: $value', style: small)
      : pw.Row(children: [
          cell('$label:', style: small),
          pw.SizedBox(width: 4),
          cell(value, style: small),
        ]);

  final doc = pw.Document();
  doc.addPage(
    pw.MultiPage(
      theme: theme,
      textDirection: pageDirection,
      build: (context) => [
        pw.Header(
          level: 0,
          // The package pins a header's child to its top left and shrinks the
          // rule under it to fit. A title on a right-to-left page has to be
          // handed the whole width before its own alignment can put it where
          // the rest of the page starts.
          child: rtl
              ? pw.Row(children: [pw.Expanded(child: cell(heading))])
              : cell(heading),
        ),
        if (subtitles.isNotEmpty) ...[
          for (final (label, value) in subtitles) subtitle(label, value),
          pw.SizedBox(height: 12),
        ],
        pw.TableHelper.fromTextArray(
          headers: [
            for (final column in header)
              cell(column, style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
          ],
          data: [
            for (final row in rows) [for (final value in row) cell(value)],
          ],
          // Cells sit where the page starts reading. The columns themselves stay
          // in the order the header lists them, which is the order the same
          // report has in the workbook and the CSV.
          cellAlignment:
              rtl ? pw.Alignment.centerRight : pw.Alignment.centerLeft,
        ),
      ],
    ),
  );
  return doc.save();
}
