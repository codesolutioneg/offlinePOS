import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'analytics.dart';
import 'orders.dart';

Future<void> exportOwnerPeriodPdf({
  required String shopName,
  required String periodLabel,
  required String branchLabel,
  required PeriodKpis kpis,
  required List<OwnerOrder> completed,
  required bool arabic,
}) async {
  final types = salesByType(completed);
  final pays = salesByPayment(completed);
  final tops = topItems(completed);
  final base = await PdfGoogleFonts.cairoRegular();
  final bold = await PdfGoogleFonts.cairoBold();
  final doc = pw.Document();
  final theme = pw.ThemeData.withFont(base: base, bold: bold);

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(32),
      theme: theme,
      textDirection: arabic ? pw.TextDirection.rtl : pw.TextDirection.ltr,
      build: (context) => [
        pw.Text('Dishflow Owner',
            style: pw.TextStyle(
                fontSize: 22, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 4),
        pw.Text(shopName, style: const pw.TextStyle(fontSize: 14)),
        pw.SizedBox(height: 2),
        pw.Text('$periodLabel · $branchLabel',
            style: const pw.TextStyle(fontSize: 12, color: PdfColors.grey700)),
        pw.SizedBox(height: 20),
        pw.Text(arabic ? 'الملخص' : 'Summary',
            style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 8),
        _kv(arabic ? 'صافي المبيعات' : 'Net sales', money(kpis.netSales)),
        _kv(arabic ? 'الطلبات' : 'Orders', '${kpis.orders}'),
        _kv(arabic ? 'متوسط الفاتورة' : 'Average check', money(kpis.avgCheck)),
        _kv(arabic ? 'المرتجعات' : 'Returns', money(kpis.refunds)),
        _kv(arabic ? 'التكلفة' : 'Cost', money(kpis.cost)),
        _kv(arabic ? 'الهامش' : 'Margin', money(kpis.margin)),
        pw.SizedBox(height: 18),
        pw.Text(arabic ? 'حسب نوع الطلب' : 'By order type',
            style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 6),
        for (final t in types) _kv(t.label, money(t.value)),
        pw.SizedBox(height: 14),
        pw.Text(arabic ? 'حسب الدفع' : 'By payment',
            style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 6),
        for (final t in pays) _kv(t.label, money(t.value)),
        pw.SizedBox(height: 14),
        pw.Text(arabic ? 'أعلى الأصناف' : 'Top items',
            style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 6),
        for (final t in tops)
          _kv('${t.name} × ${t.qty.toStringAsFixed(t.qty == t.qty.roundToDouble() ? 0 : 1)}',
              money(t.net)),
        pw.SizedBox(height: 24),
        pw.Text(
          'Generated ${DateTime.now().toIso8601String()}',
          style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
        ),
      ],
    ),
  );

  await Printing.layoutPdf(
    onLayout: (_) async => doc.save(),
    name: 'dishflow-owner-$periodLabel.pdf',
  );
  await HapticFeedback.lightImpact();
}

pw.Widget _kv(String k, String v) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 3),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Expanded(child: pw.Text(k)),
          pw.Text(v, style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
        ],
      ),
    );
