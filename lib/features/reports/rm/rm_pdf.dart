import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/export/pdf_fonts.dart';
import 'rm_layout.dart';

/// The laid-out report as a PDF: every cell where the screen shows it, so the
/// paper and the preview are one design.
Future<List<int>> buildRmPdf(RmDocument document) async {
  final theme =
      pdfNeedsEmbeddedFont(document.items.map((i) => i.text))
          ? await unicodePdfTheme()
          : null;
  final doc = pw.Document();
  for (var page = 0; page < document.pages; page++) {
    doc.addPage(pw.Page(
      theme: theme,
      pageFormat: PdfPageFormat(document.pageWidth, document.pageHeight),
      margin: pw.EdgeInsets.zero,
      build: (context) => pw.Stack(children: [
        for (final item in document.on(page)) _placed(item, theme != null),
      ]),
    ));
  }
  return doc.save();
}

pw.Widget _placed(RmPlaced item, bool unicode) {
  final c = item.cell;
  if (c.kind == RmKind.rule) {
    return pw.Positioned(
      left: item.x,
      top: item.y + 6,
      child: pw.Container(width: item.width, height: 0.8, color: PdfColors.black),
    );
  }
  return pw.Positioned(
    left: item.x,
    top: item.y,
    child: pw.SizedBox(
      width: item.width,
      child: pw.Text(
        item.text,
        maxLines: 1,
        overflow: pw.TextOverflow.clip,
        textAlign: switch (c.justify) {
          1 => pw.TextAlign.center,
          2 => pw.TextAlign.right,
          _ => pw.TextAlign.left,
        },
        textDirection: unicode && pdfIsRightToLeft(item.text)
            ? pw.TextDirection.rtl
            : null,
        style: pw.TextStyle(
          fontSize: c.fontSize,
          fontWeight: c.bold ? pw.FontWeight.bold : null,
          fontStyle: c.italic ? pw.FontStyle.italic : null,
          decoration: c.underline ? pw.TextDecoration.underline : null,
          color: item.placeholder ? PdfColors.grey500 : PdfColors.black,
        ),
      ),
    ),
  );
}
