import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:printing/printing.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../flash/flash_kind.dart';
import '../flash/flash_report_data.dart';
import '../flash/flash_slip.dart';
import '../theme.dart';

class FlashPreviewScreen extends StatefulWidget {
  const FlashPreviewScreen({
    super.key,
    required this.data,
    required this.kind,
    required this.shopName,
    required this.arabic,
  });

  final FlashReportData data;
  final FlashKind kind;
  final String shopName;
  final bool arabic;

  @override
  State<FlashPreviewScreen> createState() => _FlashPreviewScreenState();
}

class _FlashPreviewScreenState extends State<FlashPreviewScreen> {
  late final List<FlashSlipLine> _slip;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    _slip = buildFlashSlip(
      data: widget.data,
      kind: widget.kind,
      shopName: widget.shopName.isEmpty ? 'Dishflow' : widget.shopName,
    );
  }

  Future<void> _copy() async {
    final text = _slip.map((l) => l.text).join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        widget.arabic ? 'تم النسخ' : 'Copied',
        style: GoogleFonts.cairo(),
      ),
    ));
  }

  Future<void> _sharePdf() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final doc = pw.Document();
      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.roll80,
          build: (ctx) => [
            for (final line in _slip)
              pw.Text(
                line.text,
                style: pw.TextStyle(
                  fontSize: 9,
                  fontWeight:
                      line.bold ? pw.FontWeight.bold : pw.FontWeight.normal,
                ),
              ),
          ],
        ),
      );
      await Printing.sharePdf(
        bytes: await doc.save(),
        filename: '${widget.data.title.replaceAll(' ', '_')}.pdf',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(widget.data.title),
        actions: [
          IconButton(
            tooltip: widget.arabic ? 'نسخ' : 'Copy',
            onPressed: _copy,
            icon: const Icon(Icons.copy_rounded),
          ),
          IconButton(
            tooltip: widget.arabic ? 'مشاركة PDF' : 'Share PDF',
            onPressed: _busy ? null : _sharePdf,
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.ios_share_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF0F172A).withValues(alpha: 0.06),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: SelectableText.rich(
              TextSpan(
                children: [
                  for (final line in _slip)
                    TextSpan(
                      text: '${line.text}\n',
                      style: TextStyle(
                        fontFamily: 'Courier New',
                        fontFamilyFallback: const [
                          'Consolas',
                          'Courier',
                          'monospace',
                        ],
                        fontSize: 12,
                        height: 1.3,
                        fontWeight:
                            line.bold ? FontWeight.w700 : FontWeight.w400,
                        color: Colors.black,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _sharePdf,
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: Text(
              widget.arabic ? 'مشاركة / طباعة PDF' : 'Share / print PDF',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}
