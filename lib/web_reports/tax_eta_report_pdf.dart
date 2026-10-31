import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/export/pdf_fonts.dart';
import 'site_api.dart';

/// Dishflow-shaped ETA submitted-invoices PDF («تقرير فواتير ETA المرسلة»).
Future<List<int>> buildEtaSubmittedReportPdf({
  required List<SiteTaxInvoice> invoices,
  required String branchName,
  required String periodLabel,
  DateTime? printedAt,
}) async {
  final theme = await unicodePdfTheme();
  final now = printedAt ?? DateTime.now();
  final money = (double v) => v.toStringAsFixed(2);
  String two(int n) => n.toString().padLeft(2, '0');
  String fmtDt(DateTime? t) {
    if (t == null) return '—';
    final l = t.toLocal();
    return '${l.year}-${two(l.month)}-${two(l.day)}  ${two(l.hour)}:${two(l.minute)}';
  }

  final byPayment = <String, List<SiteTaxInvoice>>{};
  for (final inv in invoices) {
    final key = inv.paymentMethod.trim().isEmpty ? '—' : inv.paymentMethod.trim();
    (byPayment[key] ??= []).add(inv);
  }
  final paymentKeys = byPayment.keys.toList()..sort();

  final grandTotal = invoices.fold<double>(0, (s, i) => s + i.amount);

  pw.Widget cell(
    String text, {
    pw.FontWeight? weight,
    double size = 9,
    PdfColor? color,
    pw.TextAlign align = pw.TextAlign.right,
    pw.TextDirection dir = pw.TextDirection.rtl,
  }) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
      child: pw.Text(
        text,
        textAlign: align,
        textDirection: dir,
        style: pw.TextStyle(
          fontSize: size,
          fontWeight: weight,
          color: color,
        ),
      ),
    );
  }

  pw.Widget summaryBoxes(double total, {required String label, String? subtitle}) {
    final pre = total / 1.14;
    final tax = total - pre;
    pw.Widget box({
      required String title,
      required double amount,
      required PdfColor bg,
      required PdfColor titleColor,
      required PdfColor valueColor,
    }) {
      return pw.Expanded(
        child: pw.Container(
          decoration: pw.BoxDecoration(
            color: bg,
            borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
          ),
          padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            mainAxisAlignment: pw.MainAxisAlignment.center,
            children: [
              pw.Text(
                title,
                textDirection: pw.TextDirection.rtl,
                style: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold,
                  fontSize: 8,
                  color: titleColor,
                ),
              ),
              pw.SizedBox(height: 4),
              pw.Text(
                '${money(amount)} ج.م',
                style: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold,
                  fontSize: 11,
                  color: valueColor,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 5),
      child: pw.SizedBox(
        height: 58,
        child: pw.Row(
          children: [
            pw.Expanded(
              child: pw.Container(
                decoration: const pw.BoxDecoration(
                  color: PdfColors.blueGrey200,
                  borderRadius: pw.BorderRadius.all(pw.Radius.circular(4)),
                ),
                padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  mainAxisAlignment: pw.MainAxisAlignment.center,
                  children: [
                    pw.Text(
                      label,
                      textDirection: pw.TextDirection.rtl,
                      style: pw.TextStyle(
                        fontWeight: pw.FontWeight.bold,
                        fontSize: 9,
                        color: PdfColors.blueGrey800,
                      ),
                    ),
                    if (subtitle != null)
                      pw.Text(
                        subtitle,
                        textDirection: pw.TextDirection.rtl,
                        style: const pw.TextStyle(
                          fontSize: 8,
                          color: PdfColors.blueGrey700,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            pw.SizedBox(width: 5),
            box(
              title: 'بعد الضريبة',
              amount: total,
              bg: PdfColors.teal100,
              titleColor: PdfColors.teal800,
              valueColor: PdfColors.teal900,
            ),
            pw.SizedBox(width: 5),
            box(
              title: 'قبل الضريبة',
              amount: pre,
              bg: PdfColors.blueGrey50,
              titleColor: PdfColors.blueGrey700,
              valueColor: PdfColors.blueGrey900,
            ),
            pw.SizedBox(width: 5),
            box(
              title: 'قيمة الضريبة 14%',
              amount: tax,
              bg: PdfColors.orange50,
              titleColor: PdfColors.orange800,
              valueColor: PdfColors.orange900,
            ),
          ],
        ),
      ),
    );
  }

  final sections = <pw.Widget>[];
  var rowIdx = 1;
  for (final pm in paymentKeys) {
    final orders = byPayment[pm]!;
    final pmTotal = orders.fold<double>(0, (s, e) => s + e.amount);
    sections.add(pw.SizedBox(height: 12));
    sections.add(
      pw.Container(
        decoration: const pw.BoxDecoration(
          color: PdfColors.blueGrey200,
          border: pw.Border(
            bottom: pw.BorderSide(color: PdfColors.blueGrey400, width: 0.5),
          ),
        ),
        padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: pw.Text(
          '$pm  —  ${orders.length} طلب',
          textDirection: pw.TextDirection.rtl,
          style: pw.TextStyle(
            fontWeight: pw.FontWeight.bold,
            fontSize: 10,
            color: PdfColors.blueGrey800,
          ),
        ),
      ),
    );

    final tableRows = <pw.TableRow>[
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: PdfColors.blueGrey100),
        children: [
          cell('#',
              weight: pw.FontWeight.bold,
              size: 8,
              color: PdfColors.blueGrey700,
              align: pw.TextAlign.center,
              dir: pw.TextDirection.ltr),
          cell('رقم الطلب',
              weight: pw.FontWeight.bold, size: 8, color: PdfColors.blueGrey700),
          cell('وقت الإرسال',
              weight: pw.FontWeight.bold, size: 8, color: PdfColors.blueGrey700),
          cell('قبل الضريبة',
              weight: pw.FontWeight.bold,
              size: 8,
              color: PdfColors.blueGrey700,
              align: pw.TextAlign.right),
          cell('بعد الضريبة',
              weight: pw.FontWeight.bold,
              size: 8,
              color: PdfColors.blueGrey700,
              align: pw.TextAlign.right),
        ],
      ),
      ...orders.map((s) {
        final amt = s.amount;
        final pre = amt / 1.14;
        final isOdd = rowIdx.isOdd;
        final name =
            s.orderNumber.trim().isEmpty ? s.id : s.orderNumber.trim();
        return pw.TableRow(
          decoration: pw.BoxDecoration(
            color: isOdd ? PdfColors.white : PdfColors.grey50,
          ),
          children: [
            cell('${rowIdx++}',
                size: 8.5,
                align: pw.TextAlign.center,
                dir: pw.TextDirection.ltr),
            cell(name, size: 8.5),
            cell(fmtDt(s.etaSubmittedAt),
                size: 8,
                dir: pw.TextDirection.ltr,
                align: pw.TextAlign.left),
            cell(money(pre),
                size: 8.5,
                align: pw.TextAlign.left,
                dir: pw.TextDirection.ltr,
                color: PdfColors.blueGrey700),
            cell(money(amt),
                weight: pw.FontWeight.bold,
                size: 8.5,
                align: pw.TextAlign.left,
                dir: pw.TextDirection.ltr,
                color: PdfColors.teal800),
          ],
        );
      }),
    ];

    sections.add(
      pw.Table(
        border: pw.TableBorder.all(color: PdfColors.blueGrey200, width: 0.5),
        columnWidths: const {
          0: pw.FixedColumnWidth(25),
          1: pw.FlexColumnWidth(1.6),
          2: pw.FlexColumnWidth(2.2),
          3: pw.FixedColumnWidth(68),
          4: pw.FixedColumnWidth(68),
        },
        children: tableRows,
      ),
    );
    sections.add(
      summaryBoxes(pmTotal, label: 'إجمالي $pm', subtitle: '${orders.length} طلب'),
    );
  }

  final doc = pw.Document(theme: theme);
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.symmetric(horizontal: 28, vertical: 32),
      build: (ctx) => [
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  'طُبع: ${fmtDt(now)}',
                  textDirection: pw.TextDirection.rtl,
                  style: const pw.TextStyle(
                    fontSize: 8,
                    color: PdfColors.blueGrey400,
                  ),
                ),
                pw.Text(
                  '${invoices.length} فاتورة',
                  textDirection: pw.TextDirection.rtl,
                  style: const pw.TextStyle(
                    fontSize: 8.5,
                    color: PdfColors.blueGrey500,
                  ),
                ),
              ],
            ),
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Text(
                  'تقرير فواتير ETA المرسلة',
                  textDirection: pw.TextDirection.rtl,
                  style: pw.TextStyle(
                    fontWeight: pw.FontWeight.bold,
                    fontSize: 16,
                    color: PdfColors.blueGrey900,
                  ),
                ),
                pw.SizedBox(height: 2),
                pw.Text(
                  branchName,
                  textDirection: pw.TextDirection.rtl,
                  style: const pw.TextStyle(
                    fontSize: 10,
                    color: PdfColors.blueGrey600,
                  ),
                ),
                pw.Text(
                  'الفترة: $periodLabel',
                  textDirection: pw.TextDirection.rtl,
                  style: const pw.TextStyle(
                    fontSize: 9,
                    color: PdfColors.blueGrey600,
                  ),
                ),
              ],
            ),
          ],
        ),
        pw.SizedBox(height: 8),
        pw.Divider(thickness: 1.5, color: PdfColors.blueGrey300),
        pw.SizedBox(height: 4),
        summaryBoxes(
          grandTotal,
          label: 'الإجمالي الكلي',
          subtitle: '${invoices.length} فاتورة',
        ),
        ...sections,
      ],
    ),
  );
  return doc.save();
}
