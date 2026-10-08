import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'export_header.dart';
import 'pdf_fonts.dart';

/// Builds a titled-table PDF from the same header/rows the CSV and the workbook
/// use, so a manager who wants a printable page gets the identical data. Kept
/// beside [buildCsv] so every export renders one shape of table.
///
/// [head] heads the page with the shop and the report, with the period and who
/// ran it beside them; later pages keep only the report's name and their number,
/// and the table header, which the pdf package repeats itself.
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

  const small = pw.TextStyle(fontSize: 9);
  final smallBold = pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold);

  // One line of the period / who-ran-it block: a bold label and its value. Two
  // pieces of text rather than one string, on every page: joined, they are a
  // single paragraph to the bidirectional pass, and that pass rearranges a date
  // sitting inside an Arabic line, so the stamp came back reading 16-08-2026.
  // Apart, they never meet, and the row itself turns round with the page.
  pw.Widget subtitle(String label, String value) =>
      pw.Row(mainAxisSize: pw.MainAxisSize.min, children: [
        cell('$label:', style: smallBold),
        pw.SizedBox(width: 4),
        cell(value, style: small),
      ]);

  // The shop and the report it is, which the page is headed with; they are left
  // out of the block beside them rather than printed twice.
  final shop = head?.shop ?? '';
  final beside = [
    for (final (label, value) in subtitles)
      if (value != heading && (shop.isEmpty || value != shop)) (label, value),
  ];
  final pageLabel = head?.pageLabel ?? 'Page';

  // A column of figures lines up on its last digit, the way a ledger does.
  bool figures(int column) =>
      rows.isNotEmpty &&
      rows.every((r) =>
          column >= r.length ||
          r[column].trim().isEmpty ||
          _figure.hasMatch(r[column].trim()));
  final start = rtl ? pw.Alignment.centerRight : pw.Alignment.centerLeft;
  // On the right whichever way the page reads: digits run left to right in both.
  final alignments = {
    for (var i = 0; i < header.length; i++)
      i: figures(i) ? pw.Alignment.centerRight : start,
  };

  final doc = pw.Document();
  doc.addPage(
    pw.MultiPage(
      theme: theme,
      textDirection: pageDirection,
      margin: const pw.EdgeInsets.all(28),
      // The back-office layout: what and when on one side, the shop and the
      // report in the middle, the page on the other, and a rule under it. The
      // first page carries the whole block; the ones after it only say which
      // report and which page they are.
      header: (context) => pw.Column(children: [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  if (context.pageNumber == 1)
                    for (final (label, value) in beside) subtitle(label, value),
                ],
              ),
            ),
            pw.Expanded(
              child: pw.Column(children: [
                if (shop.isNotEmpty)
                  cell(shop,
                      style: pw.TextStyle(
                          fontSize: 13, fontWeight: pw.FontWeight.bold)),
                cell(heading,
                    style: pw.TextStyle(
                        fontSize: 11, fontWeight: pw.FontWeight.bold)),
              ]),
            ),
            pw.Expanded(
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.end,
                children: [subtitle(pageLabel, '${context.pageNumber}')],
              ),
            ),
          ],
        ),
        pw.SizedBox(height: 8),
        pw.Divider(thickness: 1),
        pw.SizedBox(height: 4),
      ]),
      build: (context) => [
        pw.TableHelper.fromTextArray(
          headers: [
            for (final column in header) cell(column, style: smallBold),
          ],
          data: [
            for (final row in rows)
              [for (final value in row) cell(value, style: small)],
          ],
          // Ruled, not boxed: a line under the header, a hair between the rows
          // and a line to close the table.
          border: const pw.TableBorder(
            bottom: pw.BorderSide(width: 0.8),
            horizontalInside: pw.BorderSide(width: 0.3, color: PdfColors.grey400),
          ),
          headerDecoration: const pw.BoxDecoration(
            border: pw.Border(bottom: pw.BorderSide(width: 1)),
          ),
          cellPadding:
              const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          // Cells sit where the page starts reading, figures on the right. The
          // columns themselves stay in the order the header lists them, which is
          // the order the same report has in the workbook and the CSV.
          cellAlignment: start,
          cellAlignments: alignments,
          headerAlignments: alignments,
        ),
      ],
    ),
  );
  return doc.save();
}

/// A cell that is a figure: digits with their separators, a sign, a percent.
final _figure = RegExp(r'^[-+]?[\d,]*\.?\d+%?$');
