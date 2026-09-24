import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/i18n/l10n.dart';
import '../../../core/theme/app_colors.dart';
import '../../../domain/catalogue.dart';
import 'flash_report_data.dart';
import 'flash_thermal_escpos.dart';
import 'flash_type_dialog.dart';

/// Flash preview — shows the **same monospaced Dishflow slip** that prints,
/// and auto-prints to the receipt printer on open.
class FlashPreviewScreen extends StatefulWidget {
  const FlashPreviewScreen({
    super.key,
    required this.data,
    required this.kind,
    required this.formatAmount,
    this.shopName = '',
    this.categories = const [],
    this.cashTenderIds = const {},
    this.onPrint,
    this.onPrintFlash,
    this.staffNames = const {},
    this.autoPrint = true,
  });

  final FlashReportData data;
  final FlashKind kind;
  final String shopName;
  final List<Category> categories;
  final Set<int> cashTenderIds;
  final String Function(double) formatAmount;
  final Future<void> Function(String title, List<(String, String)> rows)?
      onPrint;
  final Future<void> Function(FlashReportData data, FlashKind kind)?
      onPrintFlash;
  final Map<String, String> staffNames;

  /// When true (default), send to the receipt printer as soon as the screen opens.
  final bool autoPrint;

  @override
  State<FlashPreviewScreen> createState() => _FlashPreviewScreenState();
}

class _FlashPreviewScreenState extends State<FlashPreviewScreen> {
  bool _printing = false;
  String? _printStatus;
  late final List<FlashThermalLine> _slip;

  @override
  void initState() {
    super.initState();
    _slip = FlashThermalEscPos.lines(
      data: widget.data,
      kind: flashThermalKindFor(widget.kind),
      shopName: widget.shopName.isEmpty ? 'Shop' : widget.shopName,
      categoryNameOf: _categoryName,
      isCashPayment: _isCash,
    );
    if (widget.autoPrint &&
        (widget.onPrintFlash != null || widget.onPrint != null)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_print(auto: true));
      });
    }
  }

  String _categoryName(int? id) {
    if (id == null) return 'Other';
    for (final c in widget.categories) {
      if (c.id == id) return c.name;
    }
    return 'Other';
  }

  bool _isCash(String label) {
    final want = label.trim().toLowerCase();
    if (want.contains('cash') || want == 'نقدي' || want == 'كاش') return true;
    // Match catalogue cash methods by printed label when ids are known.
    return false;
  }

  Future<void> _print({bool auto = false}) async {
    if (_printing) return;
    setState(() {
      _printing = true;
      _printStatus = null;
    });
    try {
      final flash = widget.onPrintFlash;
      if (flash != null) {
        await flash(widget.data, widget.kind);
      } else {
        final onPrint = widget.onPrint;
        if (onPrint == null) return;
        await onPrint(
          widget.data.title,
          widget.data.thermalRows(widget.formatAmount),
        );
      }
      if (!mounted) return;
      setState(() {
        _printStatus = auto
            ? tr(context, 'Sent to receipt printer')
            : tr(context, 'Summary sent to printer');
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_printStatus!),
        duration: const Duration(seconds: 2),
      ));
    } catch (e) {
      if (!mounted) return;
      final raw = '$e';
      final msg = raw.contains('No receipt printer')
          ? tr(context, 'No receipt printer configured')
          : raw.contains('Printer offline')
              ? tr(context, 'Printer offline — job held')
              : raw;
      setState(() => _printStatus = msg);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${tr(context, 'Print failed')}: $msg'),
        backgroundColor: AppColors.error,
      ));
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canPrint =
        widget.onPrintFlash != null || widget.onPrint != null;
    return Scaffold(
      key: const Key('flash-preview-screen'),
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(
        title: Text(widget.data.title),
        actions: [
          if (canPrint)
            IconButton(
              key: const Key('flash-print'),
              tooltip: tr(context, 'Print'),
              onPressed: _printing ? null : () => _print(),
              icon: _printing
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.print),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
        children: [
          if (_printStatus != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _printStatus!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _printStatus!.toLowerCase().contains('fail') ||
                          _printStatus!.contains('offline') ||
                          _printStatus!.contains('No receipt')
                      ? AppColors.error
                      : AppColors.success,
                ),
              ),
            ),
          // Monospace slip — same lines as the thermal print (Dishflow).
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE2E8F0)),
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
                        fontSize: 11.5,
                        height: 1.25,
                        fontWeight:
                            line.bold ? FontWeight.w700 : FontWeight.w400,
                        color: Colors.black,
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (canPrint) ...[
            const SizedBox(height: 20),
            FilledButton.icon(
              key: const Key('flash-print-button'),
              onPressed: _printing ? null : () => _print(),
              icon: const Icon(Icons.print),
              label: Text(tr(context, 'Print again')),
            ),
          ],
        ],
      ),
    );
  }
}
