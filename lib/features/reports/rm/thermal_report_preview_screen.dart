import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/i18n/l10n.dart';
import '../../../core/theme/app_colors.dart';
import 'thermal_report.dart';

/// Receipt-printer preview for a [ThermalReport] — same monospaced slip that
/// prints, Flash-style: see it, then print (or print again).
class ThermalReportPreviewScreen extends StatefulWidget {
  const ThermalReportPreviewScreen({
    super.key,
    required this.report,
    required this.onPrint,
    this.shopName = '',
    this.columns = 42,
    this.autoPrint = false,
  });

  final ThermalReport report;
  final String shopName;
  final int columns;
  final Future<void> Function(ThermalReport report) onPrint;

  /// When true, send to the receipt printer as soon as the screen opens.
  final bool autoPrint;

  @override
  State<ThermalReportPreviewScreen> createState() =>
      _ThermalReportPreviewScreenState();
}

class _ThermalReportPreviewScreenState
    extends State<ThermalReportPreviewScreen> {
  bool _printing = false;
  String? _printStatus;
  late final List<ThermalLine> _slip;

  @override
  void initState() {
    super.initState();
    _slip = thermalReportSlipLines(
      widget.report,
      shopName: widget.shopName,
      columns: widget.columns,
    );
    if (widget.autoPrint) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_print(auto: true));
      });
    }
  }

  static String _padLine(ThermalLine line, int width) {
    final text = line.text;
    if (!line.center || text.length >= width) return text;
    final left = (width - text.length) ~/ 2;
    return (' ' * left) + text;
  }

  Future<void> _print({bool auto = false}) async {
    if (_printing) return;
    setState(() {
      _printing = true;
      _printStatus = tr(context, 'Printing…');
    });
    try {
      await widget.onPrint(widget.report);
      if (!mounted) return;
      setState(() {
        _printStatus = auto
            ? tr(context, 'Sent to receipt printer')
            : tr(context, 'Sent to the receipt printer');
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_printStatus!),
        duration: const Duration(seconds: 2),
      ));
    } catch (e) {
      if (!mounted) return;
      final raw = '$e';
      final offline = raw.contains('Printer offline');
      final missing = raw.contains('No receipt printer');
      final address = offline && raw.contains(': ')
          ? raw.substring(raw.lastIndexOf(': ') + 2).trim()
          : null;
      final msg = missing
          ? tr(context, 'No receipt printer configured')
          : offline
              ? tr(context, 'Receipt printer is not connected')
              : raw;
      setState(() {
        _printStatus = msg;
        _printing = false;
      });
      await _showPrintFailed(msg, address: address, canRetry: !missing);
    } finally {
      if (mounted && _printing) setState(() => _printing = false);
    }
  }

  Future<void> _showPrintFailed(String message,
      {String? address, required bool canRetry}) async {
    final retry = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('thermal-print-failed'),
        icon: const Icon(Icons.print_disabled, color: AppColors.error, size: 36),
        title: Text(message),
        content: Text([
          if (address != null && address.isNotEmpty)
            tr(ctx, 'Printer address: {a}').replaceAll('{a}', address),
          canRetry
              ? tr(ctx,
                  'Check the printer is on, has paper, and is on the same network as this till.')
              : tr(ctx,
                  'Set up the receipt printer for this till in Settings › Printers.'),
        ].join('\n')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(tr(ctx, 'Close')),
          ),
          if (canRetry)
            FilledButton(
              key: const Key('thermal-print-retry'),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(tr(ctx, 'Try again')),
            ),
        ],
      ),
    );
    if (retry == true && mounted) await _print();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('thermal-report-preview'),
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(
        title: Text(widget.report.title),
        actions: [
          IconButton(
            key: const Key('thermal-preview-print'),
            tooltip: tr(context, 'Print'),
            onPressed: _printing ? null : () => unawaited(_print()),
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
                          _printStatus!.contains('No receipt') ||
                          _printStatus!.contains('مش متصلة')
                      ? AppColors.error
                      : AppColors.success,
                ),
              ),
            ),
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
                      text: '${_padLine(line, widget.columns)}\n',
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
          const SizedBox(height: 20),
          FilledButton.icon(
            key: const Key('thermal-preview-print-button'),
            onPressed: _printing ? null : () => unawaited(_print()),
            icon: const Icon(Icons.print),
            label: Text(tr(context, 'Print')),
          ),
        ],
      ),
    );
  }
}
